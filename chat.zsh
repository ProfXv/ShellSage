MODEL_URL=`eval echo \$"$SERVICE"_MODEL_URL`
API_KEY=`eval echo \$"$SERVICE"_API_KEY`

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
    tools=$(printf "%s\n" "${tools_list[@]}" | xargs -I {} cat ~/.chat/tools/{}.json | jq -s '.')
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
            tools: $tools,
            tool_choice: "auto",
            stream: $stream
        }'
    )
    # 发送请求
    curl --no-buffer -s $MODEL_URL \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "$request_body"
}

execute_conversation() {
    send_request -t "terminal_command" -s | tee -a /tmp/conversation_log |
        while read -r line; do
            if [ -z "$line" ]; then
                continue
            elif echo $line | grep -q ^data; then
                line=$(echo -E $line | sed -u 's/^data: //')
                if [ "$line" = "[DONE]" ]; then continue; fi
                delta=$(echo -E $line | jq '.choices[0].delta')
                echo -E $delta | jq -je '.content // empty' | tee -a $RESPONSE_FILE ||
                {
                    tool_calls=$(echo -E $delta | jq '.tool_calls' | tee -a /tmp/tool_calls.json)
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
                fi
            else
                echo -ne "\n$line"
            fi
        done
    if [ -z "$line" ]; then
        echo \\n
        echo "\033[34mFinish reason: $finish_reason\033[0m" >&2
        echo "\033[33mUsage: $in_tokens + $out_tokens = $total_tokens\033[0m" >&2
        echo "\033[32m[DONE]\033[0m" >&2
    else
        echo $line | jq
        echo -e "\n" >> /tmp/conversation_log
    fi
    RESPONSE_STATE=false
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
          ' /tmp/tool_calls.json)
        FUNCTION=$(echo -E $tool_calls | jq '.[0].function')
        tool_call_id=$(echo -E $tool_calls | jq -r '.[0].id')
        rm /tmp/tool_calls.json
    fi
    append_to_conversation -r assistant -c "$(< $RESPONSE_FILE)" -t "$tool_calls"
    rm $RESPONSE_FILE
    unset tool_calls
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
            handle_conversation
        else
            zle -M "No available query since last reply." # could be intelligent reminders later
        fi
        MANUAL=false
    elif ! type ${BUFFER%% *} &>/dev/null; then
        append_to_conversation -r user -c "$BUFFER"
        handle_conversation
        MANUAL=false
    else
        zle accept-line
        RESPONSE_STATE=true
        MANUAL=true
    fi
}

precmd() {
    if $RESPONSE_STATE; then
        result=`kitty @ get-text --extent last_cmd_output`
        if $MANUAL; then
            result=`jq -nc --arg in "$(fc -ln -1)" --arg out "$result" '{$in, $out}'`
            append_to_conversation -r user -c "$result"
        else
            append_to_conversation -r tool -c "$result"
        fi
        if [[ -n $FUNCTION ]]; then
            kitten @ send-key Return
            unset FUNCTION
        fi
    fi
}

# 定义文件名常量
[ -z "$PROJECT_HOME" ] && PROJECT_HOME=$HOME
CONVERSATION_HOME=$PROJECT_HOME/Documents/conversations
mkdir -p $CONVERSATION_HOME
CONVERSATION_FILE=$CONVERSATION_HOME/`date +%s`.jsonl
RESPONSE_FILE=/tmp/response.md
RESPONSE_STATE=false

mkdir -p /tmp/conversations
append_to_conversation -r system -c "$(< ~/.chat/system.txt)"

zle -N natural_language_widget
bindkey '^M' natural_language_widget
bindkey '^J' natural_language_widget
# 定义 command_not_found_handler 函数
# command_not_found_handler() {
#     append_to_conversation -r user -c "$*"
#     handle_conversation
# }
# unsetopt cdable_vars

check_conversation() {zle -M "`cat $CONVERSATION_FILE`"}
zle -N check_conversation
# 暂时抑制这个功能，因为发现跟划词生成存在冲突。
# 以及M字母同样被上面征用到同一功能。
# bindkey '^M' check_conversation

back_conversation() {
    sed -i '$ d' $CONVERSATION_FILE 
    RESPONSE_STATE=true
    zle -M "`tail -1 $CONVERSATION_FILE`"
}
zle -N back_conversation
bindkey '^[r' back_conversation
