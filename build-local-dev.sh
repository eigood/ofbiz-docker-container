#!/bin/bash

set -e

set -x
PATH_OFBIZ=
PATH_WORDPRESS=
ofbiz_install_command=load-data
OFBIZ_COMMONS_DAEMON_START=org.ofbiz.base.start.CommonsDaemonStart
DO_SNAPSHOT=
NGINX_API_PASSTHROUGH=api

declare -a args=()
while [[ $# -gt 0 ]]; do
	arg="$1"
	shift
	case "$arg" in
		(--flavor|--flavour)
			FLAVOR="$1"
			shift
			;;
		(--ofbiz)
			PATH_OFBIZ="$1"
			shift
			;;
		(--old-ofbiz)
			ofbiz_install_command=install
			OFBIZ_COMMONS_DAEMON_START=org.ofbiz.base.start.Start
			;;
		(--snapshot)
			DO_SNAPSHOT=1
			;;
		(--api)
			NGINX_API_PASSTHROUGH="$1"
			shift
			;;
		(--wordpress)
			PATH_WORDPRESS="$1"
			shift
			;;
		(*)
			args[${#args[*]}]="$arg"
			;;
	esac
done

FLAVOR=${FLAVOR:?please specify a flavor: derby, postgresql, mysql}
BASE=docker.apache.org/ofbiz/ofbiz-$FLAVOR
DEV_NAME=ofbiz-$FLAVOR

set -- "${args[@]}"
if [[ $# = 0 ]]; then
	echo "Please give a command." 1>&2
	exit 1
fi
CMD="$1"
shift

set -x

_map_container_to_uuid() {
	docker inspect "$1" 2>/dev/null | grep '"Id":' | cut -f 2 -d : | sed 's/[ ",]//g'
}

_map_image_to_uuid() {
	docker history "$1" 2>/dev/null | head -n +2 | tail -n 1 | cut -f 1 -d ' '
}

_map_image_built_on_to_uuid() {
	docker history "$1" 2>/dev/null | head -n +3 | tail -n 1 | cut -f 1 -d ' '
}

_create_if_outdated() {
	declare base_name="$1" built_name="$2" entrypoint="$3"
	shift 3
	declare base_uuid=$(_map_image_to_uuid "$base_name")
	declare built_uuid=$(_map_image_to_uuid "$built_name")
	if [[ $built_uuid ]]; then
		declare built_on_uuid=$(_map_image_built_on_to_uuid "$built_name")
		if [[ $base_uuid = $built_on_uuid ]]; then
			return;
		fi
	fi
	docker create -ti --entrypoint "$entrypoint" --volumes-from "$data_container_uuid" --privileged "$base_name" "$@"
}

_build_if_outdated() {
	declare base_name="$1" built_name="$2" entrypoint="$3"
	shift 3
	declare new_container_uuid=$(_create_if_outdated "$base_name" "$built_name" "$entrypoint" "$@")
	if ! [[ $new_container_uuid ]]; then
		return;
	fi
	docker start -ai $new_container_uuid
	docker stop $new_container_uuid
	docker commit $new_container_uuid "$built_name"
	docker rm $new_container_uuid
}


declare -a image_segments=(
	local-user
	override-settings
)
if [[ $DO_SNAPSHOT ]]; then
	image_segments[${#image_segments[*]}]="db-import"
else
	image_segments[${#image_segments[*]}]="wordpress-tables"
	image_segments[${#image_segments[*]}]="ofbiz-tables"
	image_segments[${#image_segments[*]}]="ofbiz-demo"
fi
declare -A image_segment_args=(
	[local-user]="\"$UID\" \"$(getent passwd "$UID" | cut -f 4 -d :)\" \"$(getent passwd "$UID" | cut -f 6 -d :)\""
	[override-settings]="OFBIZ_COMMONS_DAEMON_START=\"${OFBIZ_COMMONS_DAEMON_START}\" NGINX_API_PASSTHROUGH=\"${NGINX_API_PASSTHROUGH}\""
	[ofbiz-tables]="run $ofbiz_install_command delegator=default file=/tmp/empty-seed.xml"
	[ofbiz-seed]="run $ofbiz_install_command readers=seed,seed-initial,ext"
	[ofbiz-demo]="run $ofbiz_install_command"
)
git_hash=$(git rev-parse HEAD)
git_branch=$(git rev-parse --abbrev-ref HEAD)

_set_data_container() {
	data_container_name="$DEV_NAME.data.$git_hash"
	data_container_uuid=$(_map_container_to_uuid "$data_container_name")
	if [[ $1 = create && -z $data_container_uuid ]]; then
		for ((i=${#image_segments[*]} - 1; i >= 0; i--)); do
			PART="${image_segments[$i]}"
			docker rmi "$DEV_NAME.$PART:$git_hash" 2>/dev/null || true
		done
		declare -a volumes=(
	       		--volume "$HOME:/home/local-user"
			--volume "$PWD:/srv/ofbiz-app"
			--volume "$PWD/dumps:/srv/ofbiz-localdev-base/dumps"
		)
		mkdir -p "$PWD/dumps"
		if [[ $PATH_OFBIZ ]]; then
			volumes[${#volumes[*]}]="--volume"
			volumes[${#volumes[*]}]="$PATH_OFBIZ:/srv/ofbiz-app/apache-ofbiz"
		fi
		if [[ $PATH_WORDPRESS ]]; then
			volumes[${#volumes[*]}]="--volume"
			volumes[${#volumes[*]}]="$PATH_WORDPRESS:/srv/ofbiz-app/wordpress"
		fi
		data_container_uuid=$(docker create -ti "${volumes[@]}" --name "$data_container_name" --entrypoint /bin/bash $BASE)
		docker start $data_container_uuid
		docker stop $data_container_uuid
	fi

}

cmd_build() {
	_set_data_container create

	PREV="$BASE"
	for ((i=0; i < ${#image_segments[*]}; i++)); do
		echo i=$i
		PART="${image_segments[$i]}"
		NEXT="$DEV_NAME.$PART:$git_hash"
		eval declare -a part_args=\("${image_segment_args[$PART]}"\)
		_build_if_outdated "$PREV" "$NEXT" /srv/ofbiz-localdev-base/bin/onbuild.sh "$PART" "${part_args[@]}"
		PREV="$NEXT"
	done
}

cmd_run() {
	docker run --hostname localdev.ofbiz.apache.org -ti --entrypoint /srv/docker-base/bin/run-init --volumes-from "$data_container_name" --privileged -p 443:443 "$PREV" "$@" 
}

cmd_clean() {
	PREV="$BASE"
	declare image_name image_uuid
	for ((i=${#image_segments[*]}-1; i >= 0;i--)); do
		echo i=$i
		PART="${image_segments[$i]}"
		image_name="$DEV_NAME.$PART:$git_hash"
		image_uuid=$(_map_image_to_uuid "$image_name")
		if [[ $image_uuid ]]; then
			#docker rmi -f "$DEV_NAME.$PART:$git_hash" 2>/dev/null || true
			docker rmi -f "$image_uuid" || true
		fi
	done
	_set_data_container
	if [[ $data_container_uuid ]]; then
		docker rm -f "$data_container_uuid"
	fi
}

#docker create -ti --volume "$PWD:/srv/ofbiz-app" --volume "$HOME:/home/local-user" --name "$data_container_name" --entrypoint /bin/bash $BASE)
case "$CMD" in
	(clean)
		cmd_clean
		;;
	(build)
		cmd_build
		;;
	(run)
		cmd_build
		cmd_run "$@"
		;;
esac