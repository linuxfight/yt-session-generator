#!/usr/bin/env bash
set -e

# check we are running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "fatal: entrypoint.sh script must be run as root (running as $(whoami))"
    exit 1
fi

old_uid=$(id -u "$DOCKER_USER")
old_gid=$(id -g "$DOCKER_USER")

# set new uid/gid for the non-root user and take ownership of files
if [ "$old_uid" != "$PUID" ] || [ "$old_gid" != "$PGID" ]; then
    echo "Setting uid/gid $PUID:$PGID for user $DOCKER_USER"
    usermod -u "$PUID" "$DOCKER_USER"
    groupmod -g "$PGID" "$DOCKER_USER"
    set +e
    find / -path /proc -prune -o -path /sys -prune -o -uid "$old_uid" -exec chown -h "$PUID" {} +
    find / -path /proc -prune -o -path /sys -prune -o -gid "$old_gid" -exec chown -h :"$PGID" {} +
    set -e
fi

# set new gid for the render group if provided
old_render_gid=$(getent group docker-render | cut -d: -f3)
if [ -n "$RENDER_GROUP_GID" ] && [ "$old_render_gid" != "$RENDER_GROUP_GID" ]; then
    echo "Setting GID $RENDER_GROUP_GID for group docker-render"
    groupmod -g "$RENDER_GROUP_GID" docker-render
fi

# call main entrypoint as non-root user
exec su "$DOCKER_USER" -c "/entrypoint_user.sh $*"
