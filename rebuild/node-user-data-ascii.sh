#!/bin/bash
# soak 节点 user-data 模板（post-campaign-fixes-plan D3）：无 ssh_password 账号批次的
# 密码注入通道——P81 裸机交付（无密码账号 + 不传 user-data = 机器无法 SSH 管理）根治。
# ASCII-only per P75（DO user-data 非 ASCII 会被搅成 C1 控制字符）。仓内副本零凭据；
# s3-nodes.sh 经 lib/env.sh instantiate_user_data 实例化（__NODE_PASS__/__AUTHORIZED_KEY__
# 注入，密码与 s4 载荷 ssh_password 同源 NODE_PASS）后经 vpsctl create -user-data 传入。
# 只做「可 SSH 管理」最小引导，不装任何业务组件（节点组件由 NMS 纳管管线下发）。
set -Eeuxo pipefail
exec > /var/log/node-bootstrap.log 2>&1
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo '__AUTHORIZED_KEY__' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
echo 'root:__NODE_PASS__' | chpasswd
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd
