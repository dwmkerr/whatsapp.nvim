#!/bin/sh
p="nvim whatsapp plug :WhatsApp chat tree,msg right,buf compose down,:w send g? help, go bridge whatsmeow stdio, :WhatsApp pair qr, style/float/bubbles"
claude -p "$p" || codex "$p"
