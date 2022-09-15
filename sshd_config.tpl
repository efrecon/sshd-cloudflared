LogLevel DEBUG3
Port $PORT
HostKey $PWD/ssh_host_rsa_key
PidFile $PWD/sshd.pid

# PAM is necessary for password authentication on Debian-based systems
UsePAM yes

# Allow interactive authentication (default value)
#KbdInteractiveAuthentication yes

# Same as above but for older SSH versions (default value)
#ChallengeResponseAuthentication yes

# Allow password authentication (default value)
PasswordAuthentication no

# Only allow single user
AllowUsers $USER

# Only allow those keys
AuthorizedKeysFile $PWD/authorized_keys

# Turns on sftp-server
Subsystem    sftp    /usr/lib/ssh/sftp-server

# Force the shell for the user
Match User $USER
SetEnv SHELL=$SHELL
