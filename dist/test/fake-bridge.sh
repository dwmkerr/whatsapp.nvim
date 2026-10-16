#!/usr/bin/env bash
# Stand-in for wa-bridge: answers list calls with fixtures and echoes sends.
# Pushes one incoming message after the first chats.list so the UI's
# event path gets exercised too.
set -u
echo '{"event":"ready","data":{"paired":true,"connected":false}}'
echo '{"event":"connected"}'
pushed=0
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  case "$line" in
    *'"method":"chats.list"'*)
      echo '{"id":'"$id"',"result":[{"jid":"111@s.whatsapp.net","name":"Alice","is_group":false,"last_ts":1760400000,"unread":2,"last_text":"see you"},{"jid":"222@g.us","name":"Climbing","is_group":true,"last_ts":1760300000,"unread":0}]}'
      ;;
    *'"method":"messages.list"'*)
      echo '{"id":'"$id"',"result":[{"id":"m1","chat_jid":"111@s.whatsapp.net","sender":"111@s.whatsapp.net","sender_name":"Alice","text":"hello\nsecond line","ts":1760390000,"from_me":false},{"id":"m2","chat_jid":"111@s.whatsapp.net","sender":"me","sender_name":"me","text":"see you","ts":1760400000,"from_me":true,"quoted_id":"m1","quoted_text":"hello"}]}'
      if [ "$pushed" = 0 ]; then
        pushed=1
        echo '{"event":"message","data":{"chat_name":"Alice","message":{"id":"m3","chat_jid":"111@s.whatsapp.net","sender":"111@s.whatsapp.net","sender_name":"Alice","text":"pushed live","ts":1760400100,"from_me":false}}}'
      fi
      ;;
    *'"method":"message.send"'*)
      text=$(printf '%s' "$line" | sed -E 's/.*"text":"([^"]*)".*/\1/')
      echo '{"id":'"$id"',"result":{"id":"sent1","chat_jid":"111@s.whatsapp.net","sender":"me","sender_name":"me","text":"'"$text"'","ts":1760400200,"from_me":true}}'
      ;;
    *'"method":"chat.read"'*|*'"method":"chat.unread"'*|*'"method":"names.refresh"'*)
      echo '{"id":'"$id"',"result":null}'
      ;;
    *)
      echo '{"id":'"$id"',"error":"fake: unknown method"}'
      ;;
  esac
done
