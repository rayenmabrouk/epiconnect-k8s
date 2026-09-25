# Netplan v2. The NIC is matched by the static MAC that New-LabVMs.ps1 assigns,
# so the IP plan does not depend on the interface name the kernel picks.
version: 2
ethernets:
  lab0:
    match:
      macaddress: "${NODE_MAC}"
    set-name: eth0
    dhcp4: false
    dhcp6: false
    addresses: ["${NODE_IP}/${PREFIX_LENGTH}"]
    routes:
      - to: default
        via: ${GATEWAY}
    nameservers:
      addresses: [${DNS_SERVERS}]
