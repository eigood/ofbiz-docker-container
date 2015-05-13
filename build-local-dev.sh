#!/bin/bash

set -e

set -x
PATH_OFBIZ=
PATH_WORDPRESS=
ofbiz_install_command=load-data
OFBIZ_COMMONS_DAEMON_START=org.ofbiz.base.start.CommonsDaemonStart
DO_SNAPSHOT=
NGINX_API_PASSTHROUGH=api
NAMING=directory

declare -a args=()
declare -A docker_host_mapping=()
declare -A symlinks=()
while [[ $# -gt 0 ]]; do
	arg="$1"
	shift
	case "$arg" in
		(--naming)
			NAMING="$1"
			shift
			;;
		(--flavor|--flavour)
			FLAVOR="$1"
			shift
			;;
		(--add-host)
			docker_host_mapping[${1%:*}]=${1#*:}
			shift
			;;
		(--ofbiz)
			PATH_OFBIZ="$1"
			shift
			;;
		(--symlink)
			symlinks["$2"]="$1"
			shift 2
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
	declare _image_exec="${image_segment_exec[$PART]}"
	if [[ $_image_exec ]]; then
		docker start $new_container_uuid
		$_image_exec $new_container_uuid
	else
		docker start -ai $new_container_uuid
	fi
	docker stop $new_container_uuid
	docker commit $new_container_uuid "$built_name"
	docker rm $new_container_uuid
}

_exec_create_symlinks() {
	declare link_name
	for link_name in "${!symlinks[@]}"; do
		: $link_name
		docker exec "$1" mkdir -p "${link_name%/*}"
		docker exec "$1" ln -sf "${symlinks[$link_name]}" "$link_name"
	done
}


declare -a image_segments=(
	local-user
	override-settings
)
declare -A image_segment_args=(
	[local-user]="\"$UID\" \"$(getent passwd "$UID" | cut -f 4 -d :)\" \"$(getent passwd "$UID" | cut -f 6 -d :)\""
	[override-settings]="OFBIZ_COMMONS_DAEMON_START=\"${OFBIZ_COMMONS_DAEMON_START}\" NGINX_API_PASSTHROUGH=\"${NGINX_API_PASSTHROUGH}\""
	[ofbiz-tables]="run $ofbiz_install_command delegator=default file=/tmp/empty-seed.xml"
	[ofbiz-seed]="run $ofbiz_install_command readers=seed,seed-initial,ext"
	[ofbiz-demo]="run $ofbiz_install_command"
	[symlinks]="symlinks"
)
declare -A image_segment_exec=(
	[symlinks]="_exec_create_symlinks"
)

if [[ ${#symlinks[*]} -gt 0 ]]; then
	image_segments[${#image_segments[*]}]=symlinks
fi
if [[ $DO_SNAPSHOT ]]; then
	image_segments[${#image_segments[*]}]="db-import"
else
	image_segments[${#image_segments[*]}]="wordpress-tables"
	image_segments[${#image_segments[*]}]="ofbiz-tables"
	image_segments[${#image_segments[*]}]="ofbiz-demo"
fi

git_hash=$(git rev-parse HEAD)
git_PWD="${PWD/_/__}"
git_PWD="${git_PWD//"/"/_-}"
git_branch=$(git rev-parse --abbrev-ref HEAD)
git_branch="${git_branch//_/__}"
case "$NAMING" in
	(directory)
		git_naming="$git_PWD"
		;;
	(branch-directory)
		git_naming="${git_branch}_.$git_PWD"
		;;
	(hash)
		git_naming="$git_hash"
		;;
	(*)
		echo "Invalid NAMING: $NAMING." 1>&2
		exit 1
		;;
esac

_set_data_container() {
	data_container_name="$DEV_NAME.data.$git_naming"
	data_container_uuid=$(_map_container_to_uuid "$data_container_name")
	if [[ $1 = create && -z $data_container_uuid ]]; then
		for ((i=${#image_segments[*]} - 1; i >= 0; i--)); do
			PART="${image_segments[$i]}"
			docker rmi "$DEV_NAME.$PART:$git_naming" 2>/dev/null || true
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
		NEXT="$DEV_NAME.$PART:$git_naming"
		eval declare -a part_args=\("${image_segment_args[$PART]}"\)
		_build_if_outdated "$PREV" "$NEXT" /srv/ofbiz-localdev-base/bin/onbuild.sh "$PART" "${part_args[@]}"
		PREV="$NEXT"
	done
}

cmd_run() {
	declare -a docker_run_args=(
		--hostname localdev.ofbiz.apache.org
		-ti
		--entrypoint /srv/docker-base/bin/run-init
		--volumes-from "$data_container_name"
		--privileged
		-p 443:443
	)
	if [[ ${#docker_host_mapping[*]} ]]; then
		declare host
		for host in "${!docker_host_mapping[@]}"; do
			docker_run_args[${#docker_run_args[*]}]="--add-host=$host:${docker_host_mapping[$host]}"
		done
	fi
	docker run "${docker_run_args[@]}" "$PREV" "$@"
}

cmd_clean() {
	PREV="$BASE"
	declare image_name image_uuid
	for ((i=${#image_segments[*]}-1; i >= 0;i--)); do
		echo i=$i
		PART="${image_segments[$i]}"
		image_name="$DEV_NAME.$PART:$git_naming"
		image_uuid=$(_map_image_to_uuid "$image_name")
		if [[ $image_uuid ]]; then
			#docker rmi -f "$DEV_NAME.$PART:$git_naming" 2>/dev/null || true
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
