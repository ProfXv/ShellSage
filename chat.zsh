# Service configuration:
# - Assume multiple model services are pre-configured with environment variables
#   (e.g., in initialization scripts or shell profiles)
# - Each service has two variables:
#   - ${SERVICE}_MODEL_URL: Model API endpoint
#   - ${SERVICE}_API_KEY:  API key
# - SERVICE variable defines which service to use
# - MODEL_NAME variable defines which model to use
# Example configuration (could be in .bashrc/.zshrc or other init scripts):
# OPENAI_MODEL_URL="https://api.openai.com/v1"
# OPENAI_API_KEY="sk-xxxxxx"
# DEEPSEEK_MODEL_URL="https://api.deepseek.com/v1"
# DEEPSEEK_API_KEY="ds-xxxxxx"
# SERVICE=DEEPSEEK  # Switch to DeepSeek service
# MODEL_NAME=deepseek-chat  # Set model name

MODEL_URL=`eval echo \$"$SERVICE"_MODEL_URL`
API_KEY=`eval echo \$"$SERVICE"_API_KEY`

setopt pipefail

append_to_conversation() {
    local role=""
    local content=""
    local tool_calls=""
    local parsed_options=$(getopt -o "r:c:t:" --long "role:,content:,tool-calls:" -- "$@")
    if [[ $? -ne 0 ]]; then
        echo "Invalid options provided." 1>&2
        return 1
    fi
    eval set -- "$parsed_options"
    while true; do
        case "$1" in
            -r | --role)
                role="$2"
                shift 2
                ;;
            -c | --content)
                content="$2"
                shift 2
                ;;
            -t | --tool-calls)
                tool_calls="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Internal error!" 1>&2
                return 1
                ;;
        esac
    done
    case "$SERVICE" in
        DEEPSEEK|ZHIPU)
            if [ "$role" = "tool" ]; then
                jq -nc --arg role $role --arg tool_call_id "$tool_call_id" --arg content "$content" '{$role, $tool_call_id, $content}' \
                    >> $CONVERSATION_FILE
            elif [ -n "$content" ]; then
                jq -nc --arg role $role --arg content "$content" '{$role, $content}' \
                    >> $CONVERSATION_FILE
            fi
            if [ -n "$tool_calls" ]; then
                jq -nc --arg role $role --argjson tool_calls "$tool_calls" '{$role, $tool_calls}' \
                    >> $CONVERSATION_FILE
            fi
            ;;
        *)
            [ -z "$tool_calls" ] && tool_calls='{}'
            jq -nc --arg role $role --arg content "$content" --argjson tool_calls "$tool_calls" \
                '{$role, $content} + if $tool_calls != {} then {$tool_calls} else {} end' \
                >> "$CONVERSATION_FILE"
            ;;
    esac
}

send_request() {
    local tools_list=()
    local stream_option=false
    while getopts "t:s" opt; do
        case $opt in
            t)  # 工具列表选项
                tools_list+=("$OPTARG")
                ;;
            s)  # 启用流模式
                stream_option=true
                ;;
            *)
                echo "Usage: send_request -t tools_list [-s]"
                return 1
                ;;
        esac
    done
    # 生成工具的 JSON 数组
    tools=$(printf "%s\n" "${tools_list[@]}" | xargs -I {} cat $SCRIPT_DIR/tools/{}.json | jq -s '.')
    # 读取对话文件内容
    messages=$(jq -s '.' "$CONVERSATION_FILE")
    # 构造请求体的各个部分
    request_body=$(jq -n \
        --arg model_name "$MODEL_NAME" \
        --argjson messages "$messages" \
        --argjson tools "$tools" \
        --argjson stream "$stream_option" '
        {
            model: $model_name,
            messages: $messages,
            stream: $stream
        } + if $tools != [] then {tools: $tools, tool_choice: "auto"} else {} end'
    )
    # 发送请求
    curl --no-buffer -s $MODEL_URL \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "$request_body"
}

execute_conversation() {
    send_request -t "terminal_command" -s | tee -a $RUN/conversation_log | while read -r line; do
            if [ -z "$line" ]; then
                continue
            elif echo $line | grep -q ^data; then
                line=$(echo -E $line | sed -u 's/^data: //')
                if [ "$line" = "[DONE]" ]; then continue; fi
                delta=$(echo -E $line | jq '.choices[0].delta')
                {
                    echo -E $delta | jq -je '.content // empty' > /dev/null &&
                    { [ "$reasoning" = 1 ] && echo '\n\n' || true } && reasoning=0 &&
                    echo -E $delta | jq -je '.content // empty' |
                    tee -a $RESPONSE_FILE | sed 's/.*/\x1b[36m&\x1b[0m/'
                } ||
                {
                    echo -E $delta | jq -je '.reasoning_content // empty' > /dev/null &&
                    { [ "$reasoning" = 0 ] && echo '\n\n' || true } && reasoning=1 &&
                    echo -E $delta | jq -je '.reasoning_content // empty' |
                    tee -a $REASONING_RESPONSE_FILE | sed 's/.*/\x1b[34m&\x1b[0m/'
                } ||
                {
                    tool_calls=$(echo -E $delta | jq '.tool_calls' | tee -a $RUN/tool_calls.json)
                    name=$(echo -E "$tool_calls" | jq -rj '.[0].function.name // empty | . + " "')
                    if [ -n "$name" ]; then printf "\n\033[31m$name\033[0m" >&2; fi
                    echo -E $tool_calls | jq -rj '.[0].function.arguments' >&2
                }
                finish_reason=$(echo -E $line | jq -r '.choices[0].finish_reason // empty')
                usage=$(echo -E $line | jq -r '.usage // empty')
                if [ -n "$usage" ]; then
                    in_tokens=$(echo $usage | jq -r '.prompt_tokens')
                    out_tokens=$(echo $usage | jq -r '.completion_tokens')
                    total_tokens=$(echo $usage | jq -r '.total_tokens')
                    ACC_IN_TOKENS=$((ACC_IN_TOKENS + in_tokens))
                    ACC_OUT_TOKENS=$((ACC_OUT_TOKENS + out_tokens))
                    ACC_TOTAL_TOKENS=$((ACC_TOTAL_TOKENS + total_tokens))
                fi
            else
                echo -ne "\n$line"
            fi
        done
    if [ -n "$line" ]; then
        echo $line | jq
        echo -e "\n" >> $RUN/conversation_log
    fi
    if [ -n "$tool_calls" ]; then
        tool_calls=$(jq -s '
            reduce .[] as $item ([];
            if length == 0 then
                $item
            elif $item[0].function.arguments != "" then
                .[0].function.arguments += $item[0].function.arguments
            else
                .
            end
        )
        ' $RUN/tool_calls.json)
        FUNCTION=$(echo -E $tool_calls | jq '.[0].function')
        tool_call_id=$(echo -E $tool_calls | jq -r '.[0].id')
        rm $RUN/tool_calls.json
    fi
    echo \\n
    if [ -f $RESPONSE_FILE ]; then
        echo "\033[32m[DONE]\033[0m" >&2
        echo "\033[35mFinish reason: $finish_reason\033[0m" >&2
        echo "\033[33m          \tIn\tOut\tTotal\033[0m" >&2
        echo "\033[33mTurn Usage\t$in_tokens\t$out_tokens\t$total_tokens\033[0m" >&2
        echo "\033[33mAcc. Usage\t$ACC_IN_TOKENS\t$ACC_OUT_TOKENS\t$ACC_TOTAL_TOKENS\033[0m" >&2
        append_to_conversation -r assistant -c "$(< $RESPONSE_FILE)" -t "$tool_calls"
        rm $RESPONSE_FILE
        RESPONSE_STATE=false
    else
        echo "\033[31m[BROKEN]\033[0m" >&2
    fi
    unset reasoning tool_calls
}

handle_conversation() {
    zle -M ""
    echo
    execute_conversation
    echo
    if [[ -n $FUNCTION ]]; then
        name=$(echo -E $FUNCTION | jq -r '.name')
        call=$(echo -E $FUNCTION | jq -r '.arguments')
        case $name in
            terminal_command)
                BUFFER=$(echo -E $call | jq -sr '.[] | .command')
                ;;
            file_operations)
                operation=$(echo -E $call | jq -r '.operation')
                file=$(echo -E $call | jq -r '.file')
                case $operation in
                    Read)
                        cmd="cat $file"
                        ;;
                    Write)
                        content=$(echo -E $call | jq -r '.content')
                        cmd="echo \"$content\" >$file"
                        ;;
                    *)
                        cmd="echo '无效的操作'"
                        echo -E $call
                        ;;
                esac
                echo "\033[31m$operation: $file\n\033[0m" >&2
                append_to_conversation -r tool -c "$(eval $cmd)"
                unset BUFFER
                ;;
        esac
        zle accept-line
        RESPONSE_STATE=true
    else
        unset BUFFER
        zle accept-line
    fi
}

natural_language_widget() {
    if [[ -z $BUFFER ]]; then
        if $RESPONSE_STATE; then
            if [[ -n $FUNCTION ]]; then
                role=tool
                unset FUNCTION
            else
                role=user
            fi
            if [ -f $COMMAND_HISTORY_FILE ]; then
                command_history=`cat $COMMAND_HISTORY_FILE`
                rm $COMMAND_HISTORY_FILE
            fi
            append_to_conversation -r $role -c "$command_history"
            handle_conversation
        else
            zle -M "No available query since last reply." # could be intelligent reminders later
        fi
    elif ! type ${BUFFER%% *} &>/dev/null; then
        if [ -f $COMMAND_HISTORY_FILE ]; then
            command_history=`cat $COMMAND_HISTORY_FILE`
            rm $COMMAND_HISTORY_FILE
        fi
        append_to_conversation -r user -c "$command_history $BUFFER"
        handle_conversation
    else
        zle accept-line
        RESPONSE_STATE=true
    fi
}

clean_terminal_output() {
    sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g
         s/\x1b\][^\x07]*\x07//g
         s/\x1b\][^\x1b]*\x1b\\//g
         s/\r//g
         s/^%[[:space:]]*$//g'
}

preexec() {
    [[ -n $TMUX ]] && TMUX_ABS=$((`tmux display-message -p '#{history_size}+#{cursor_y}'`))
    [[ -f $LOG ]] && LOG_OFFSET=`stat --format=%s "$LOG"`
}

precmd() {
    code=$?; $RESPONSE_STATE || return; result=""
    if [[ -n $KITTY_PID ]]; then
        result=`kitty @ get-text --extent last_cmd_output`
    elif [[ -n $TMUX ]]; then
        local h2=`tmux display-message -p '#{history_size}'`
        local c2=`tmux display-message -p '#{cursor_y}'`
        result=`tmux capture-pane -p -S $((TMUX_ABS - h2)) -E $((c2 - 1))`
    elif [[ -f $LOG ]]; then
        local raw=$(tail -c $((`stat --format=%s "$LOG"` - ${LOG_OFFSET:-0})) "$LOG")
        [[ $raw != *$'\x1b[?1049h'* ]] && result=`echo "$raw" | clean_terminal_output`
    fi
    result=`jq -nc \
        --arg pwd "$(pwd)" \
        --arg in "$(fc -ln -1)" \
        --arg out "$result" \
        --arg code "$code" \
        '{$pwd, $in, $out, $code}'`
    echo $result >> $COMMAND_HISTORY_FILE
    [[ -n $FUNCTION ]] && AUTO_CONTINUE=true
}

auto_continue_widget() {
    $AUTO_CONTINUE && zle natural_language_widget; AUTO_CONTINUE=false
}
zle -N zle-line-init auto_continue_widget

SCRIPT_DIR=$(dirname "${(%):-%x}")
CONVERSATION_HOME=~/Documents/conversations
RUN=$XDG_RUNTIME_DIR/$PPID
[[ `ps -o comm= -p $PPID` == script ]] && LOG=`ps -o args= -p $PPID | awk '{print $NF}'`
mkdir -p $CONVERSATION_HOME $RUN
CONVERSATION_FILE=$CONVERSATION_HOME/`date +%s`.jsonl
RESULT_FILE=$RUN/result.txt
RESPONSE_FILE=$RUN/response.md
REASONING_RESPONSE_FILE=$RUN/reasoning_response.md
COMMAND_HISTORY_FILE=$RUN/command_history.jsonl
RESPONSE_STATE=false
AUTO_CONTINUE=false

append_to_conversation -r system -c "$(< $SCRIPT_DIR/system.md)"

zle -N natural_language_widget
bindkey '^M' natural_language_widget
bindkey '^J' natural_language_widget

# command_not_found_handler() {
#     append_to_conversation -r user -c "$*"
#     handle_conversation
# }

check_conversation() {zle -M "`cat $CONVERSATION_FILE`"}
zle -N check_conversation

back_conversation() {
    sed -i '$ d' $CONVERSATION_FILE 
    RESPONSE_STATE=true
    zle -M "`tail -1 $CONVERSATION_FILE`"
}
zle -N back_conversation
bindkey '^[r' back_conversation
