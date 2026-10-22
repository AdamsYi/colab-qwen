# 在 Colab 网页版的代码格里整段粘贴运行（先选好 A100 运行时）。
# 做三件事：部署 Huihui-Qwen3.8-27B-abliterated（A100 上 Q8 + 128K）、开 SSH、经 Cloudflare 临时隧道暴露 SSH。
# 跑完会打印：SSH 地址、root 密码、API Key、模型名。
import os, re, secrets, subprocess, time

MAC_PUBKEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ/WQAGFjVjA1vXGUiaQa/DAXLTHRUxtT6ZM/fd7YawS adamswang-mac-aorticscope"
REPO = "AdamsYi/colab-qwen"

def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

os.makedirs("/content/logs", exist_ok=True)

# 1. 后台部署模型（bootstrap.sh 从仓库 Releases 取编译好的 llama.cpp，从 HF 下模型）
api_key = "sk-colab-" + secrets.token_hex(16)
open("/content/.qwen_key", "w").write(api_key)
os.chmod("/content/.qwen_key", 0o600)
sh(f"rm -rf /content/colab-qwen && git clone -q https://github.com/{REPO} /content/colab-qwen")
subprocess.Popen("exec setsid nohup bash /content/colab-qwen/colab/bootstrap.sh "
                 ">/content/logs/bootstrap.log 2>&1 </dev/null", shell=True)

# 2. SSH：Mac 公钥免密，另设随机 root 密码给其他电脑用
root_pw = secrets.token_urlsafe(12)
sh("apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y openssh-server >/dev/null")
sh(f"mkdir -p /root/.ssh /run/sshd && echo '{MAC_PUBKEY}' >> /root/.ssh/authorized_keys "
   "&& chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys")
sh(f"echo 'root:{root_pw}' | chpasswd")
sh("printf 'PermitRootLogin yes\\nPasswordAuthentication yes\\nClientAliveInterval 30\\n' "
   ">/etc/ssh/sshd_config.d/colab.conf && /usr/sbin/sshd")

# 3. Cloudflare 临时隧道暴露 SSH（不用账号）
sh("cd /content && [ -x cloudflared ] || { curl -sL -o cloudflared "
   "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && chmod +x cloudflared; }")
subprocess.Popen("cd /content && exec setsid nohup ./cloudflared tunnel --no-autoupdate --url ssh://localhost:22 "
                 ">/content/logs/cf-ssh.log 2>&1 </dev/null", shell=True)
ssh_host = None
for _ in range(40):
    time.sleep(3)
    try:
        m = re.search(r"https://([a-z0-9-]+\.trycloudflare\.com)", open("/content/logs/cf-ssh.log").read())
    except FileNotFoundError:
        m = None
    if m:
        ssh_host = m.group(1)
        break

# 4. 等模型就绪
last = ""
while True:
    try:
        st = open("/content/logs/status").read().strip()
    except FileNotFoundError:
        st = "STARTING"
    if st != last:
        print(time.strftime("%H:%M:%S"), st)
        last = st
    if st.startswith(("READY", "FAILED")):
        break
    time.sleep(10)

print(f"""
========== 把下面这段发给 Claude ==========
SSH 地址 : {ssh_host}
root 密码: {root_pw}
API Key  : {api_key}
模型名   : Huihui-Qwen3.8-27B-abliterated
==========================================
""")
