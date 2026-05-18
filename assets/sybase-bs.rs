# --- Backup Server resource file ---
#
sybinit.release_directory: /opt/sybase
sybinit.product: bsrv
bsrv.server_name: MYSYBASE_BS
bsrv.new_config: yes
bsrv.do_upgrade: no
bsrv.do_add_backup_server: yes
bsrv.network_protocol_list: tcp
bsrv.network_hostname_list: localhost
bsrv.network_port_list: 5001
bsrv.language:
bsrv.character_set:
bsrv.tape_config_file: /opt/sybase/ASE-16_0/backup_tape.cfg
bsrv.errorlog: /opt/sybase/ASE-16_0/install/MYSYBASE_BS.log
