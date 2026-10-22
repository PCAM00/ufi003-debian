# 登录时打印 USB 主/从状态 + 当前 IP(挂在 /etc/profile.d,登录 shell 生效)
if [ -r /sys/class/udc/ci_hdrc.0/device/role ]; then
    _usb=$(cat /sys/class/udc/ci_hdrc.0/device/role 2>/dev/null)
else
    _usb="(无 UDC)"
fi

_ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{printf "%s=%s ", $2, $4}')

printf '\nUSB: %s\nIP : %s\n\n' "$_usb" "${_ip:-无}"

unset _usb _ip
