function err {
	if test "${COLORIZE}" -eq 1; then
		tput bold
		tput setaf 1
	fi

	echo "$@" 1>&2

	if test "${COLORIZE}" -eq 1; then
		tput sgr0
	fi
}

function status {
	if test "${COLORIZE}" -eq 1; then
		tput bold
		tput setaf 4
	fi

	echo "$@"

	if test "${COLORIZE}" -eq 1; then
		tput sgr0
	fi
}

function status_stage {
	if test "${COLORIZE}" -eq 1; then
		tput bold
		tput setaf 2
	fi

	echo "$@"

	if test "${COLORIZE}" -eq 1; then
		tput sgr0
	fi
}

function debug {
	if is_set "${BUILD_DEBUG}"; then
		if test "${COLORIZE}" -eq 1; then
			tput setaf 6
		fi
		echo "$@"
		if test "${COLORIZE}" -eq 1; then
			tput sgr0
		fi
	fi
}

function sed_i {
	if test "$(uname)" == "Darwin"; then
		sed -i '' "$@"
		return $?
	else
		sed -i "$@"
		return $?
	fi
}

function is_set {
	# Arguments:
	#   $1 - string value to check its truthiness
	#
	# Return:
	#   0 - is truthy (backwards I know but allows syntax like `if is_set <var>` to work)
	#   1 - is not truthy

	local val=$(tr '[:upper:]' '[:lower:]' <<<"$1")
	case $val in
	1 | t | true | y | yes)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

function have_gpg_key {
	# Arguments:
	#   $1 - GPG Key id to check if we have installed
	#
	# Return:
	#   0 - success (we can use this key for signing)
	#   * - failure (key cannot be used)

	gpg --list-secret-keys $1 >/dev/null 2>&1
	return $?
}

function parse_version {
	# Arguments:
	#   $1 - Path to the top level Consul source
	#   $2 - boolean value for whether the release version should be parsed from the source
	#   $3 - boolean whether to use GIT_DESCRIBE and GIT_COMMIT environment variables
	#   $4 - boolean whether to omit the version part of the version string. (optional)
	#
	# Return:
	#   0 - success (will write the version to stdout)
	#   * - error   (no version output)
	#
	# Notes:
	#   If the GOTAGS environment variable is present then it is used to determine which
	#   version file to use for parsing.

	local vfile="${1}/version/version.go"

	# ensure the version file exists
	if ! test -f "${vfile}"; then
		err "Error - File not found: ${vfile}"
		return 1
	fi

	local include_release="$2"
	local use_git_env="$3"
	local omit_version="$4"

	local git_version=""
	local git_commit=""

	if test -z "${include_release}"; then
		include_release=true
	fi

	if test -z "${use_git_env}"; then
		use_git_env=true
	fi

	if is_set "${use_git_env}"; then
		git_version="${GIT_DESCRIBE}"
		git_commit="${GIT_COMMIT}"
	fi

	# Get the main version out of the source file
	version_main=$(awk '$1 == "Version" && $2 == "=" { gsub(/"/, "", $3); print $3 }' <${vfile})
	release_main=$(awk '$1 == "VersionPrerelease" && $2 == "=" { gsub(/"/, "", $3); print $3 }' <${vfile})

	# try to determine the version if we have build tags
	for tag in "$GOTAGS"; do
		for vfile in $(find "${1}/version" -name "version_*.go" 2>/dev/null | sort); do
			if grep -q "// +build $tag" "${vfile}"; then
				version_main=$(awk '$1 == "Version" && $2 == "=" { gsub(/"/, "", $3); print $3 }' <${vfile})
				release_main=$(awk '$1 == "VersionPrerelease" && $2 == "=" { gsub(/"/, "", $3); print $3 }' <${vfile})
			fi
		done
	done

	local version="${version_main}"
	# override the version from source with the value of the GIT_DESCRIBE env var if present
	if test -n "${git_version}"; then
		version="${git_version}"
	fi

	local rel_ver=""
	if is_set "${include_release}"; then
		# Default to pre-release from the source
		rel_ver="${release_main}"

		# When no GIT_DESCRIBE env var is present and no release is in the source then we
		# are definitely in dev mode
		if test -z "${git_version}" -a -z "${rel_ver}" && is_set "${use_git_env}"; then
			rel_ver="dev"
		fi

		# Add the release to the version
		if test -n "${rel_ver}" -a -n "${git_commit}"; then
			rel_ver="${rel_ver} (${git_commit})"
		fi
	fi

	if test -n "${rel_ver}"; then
		if is_set "${omit_version}"; then
			echo "${rel_ver}" | tr -d "'"
		else
			echo "${version}-${rel_ver}" | tr -d "'"
		fi
		return 0
	elif ! is_set "${omit_version}"; then
		echo "${version}" | tr -d "'"
		return 0
	else
		return 1
	fi
}

function get_version {
	# Arguments:
	#   $1 - Path to the top level Consul source
	#   $2 - Whether the release version should be parsed from source (optional)
	#   $3 - Whether to use GIT_DESCRIBE and GIT_COMMIT environment variables
	#
	# Returns:
	#   0 - success (the version is also echoed to stdout)
	#   1 - error
	#
	# Notes:
	#   If a VERSION environment variable is present it will override any parsing of the version from the source
	#   In addition to processing the main version.go, version_*.go files will be processed if they have
	#   a Go build tag that matches the one in the GOTAGS environment variable. This tag processing is
	#   primitive though and will not match complex build tags in the files with negation etc.

	local vers="$VERSION"
	if test -z "$vers"; then
		# parse the OSS version from version.go
		vers="$(parse_version ${1} ${2} ${3})"
	fi

	if test -z "$vers"; then
		return 1
	else
		echo $vers
		return 0
	fi
}

function git_branch {
	# Arguments:
	#   $1 - Path to the git repo (optional - assumes pwd is git repo otherwise)
	#
	# Returns:
	#   0 - success
	#   * - failure
	#
	# Notes:
	#   Echos the current branch to stdout when successful

	local gdir="$(pwd)"
	if test -d "$1"; then
		gdir="$1"
	fi

	pushd "${gdir}" >/dev/null

	local ret=0
	local head="$(git status -b --porcelain=v2 | awk '{if ($1 == "#" && $2 =="branch.head") { print $3 }}')" || ret=1

	popd >/dev/null

	test ${ret} -eq 0 && echo "$head"
	return ${ret}
}

function git_upstream {
	# Arguments:
	#   $1 - Path to the git repo (optional - assumes pwd is git repo otherwise)
	#
	# Returns:
	#   0 - success
	#   * - failure
	#
	# Notes:
	#   Echos the current upstream branch to stdout when successful

	local gdir="$(pwd)"
	if test -d "$1"; then
		gdir="$1"
	fi

	pushd "${gdir}" >/dev/null

	local ret=0
	local head="$(git status -b --porcelain=v2 | awk '{if ($1 == "#" && $2 =="branch.upstream") { print $3 }}')" || ret=1

	popd >/dev/null

	test ${ret} -eq 0 && echo "$head"
	return ${ret}
}

function git_log_summary {
	# Arguments:
	#   $1 - Path to the git repo (optional - assumes pwd is git repo otherwise)
	#
	# Returns:
	#   0 - success
	#   * - failure
	#

	local gdir="$(pwd)"
	if test -d "$1"; then
		gdir="$1"
	fi

	pushd "${gdir}" >/dev/null

	local ret=0

	local head=$(git_branch) || ret=1
	local upstream=$(git_upstream) || ret=1
	local rev_range="${head}...${upstream}"

	if test ${ret} -eq 0; then
		status "Git Changes:"
		git log --pretty=oneline ${rev_range} || ret=1

	fi
	return $ret
}

function git_diff {
	# Arguments:
	#   $1 - Path to the git repo (optional - assumes pwd is git repo otherwise)
	#   $2 .. $N - Optional path specification
	#
	# Returns:
	#   0 - success
	#   * - failure
	#

	local gdir="$(pwd)"
	if test -d "$1"; then
		gdir="$1"
	fi

	shift

	pushd "${gdir}" >/dev/null

	local ret=0

	local head=$(git_branch) || ret=1
	local upstream=$(git_upstream) || ret=1

	if test ${ret} -eq 0; then
		status "Git Diff - Paths: $@"
		git diff ${HEAD} ${upstream} -- "$@" || ret=1
	fi
	return $ret
}

function normalize_git_url {
	url="${1#https://}"
	url="${url#git@}"
	url="${url%.git}"
	url="$(sed ${SED_EXT} -e 's/([^\/:]*)[:\/](.*)/\1:\2/' <<<"${url}")"
	echo "$url"
	return 0
}

function git_remote_url {
	# Arguments:
	#   $1 - Path to the top level Consul source
	#   $2 - Remote name
	#
	# Returns:
	#   0 - success
	#   * - error
	#
	# Note:
	#   The push url for the git remote will be echoed to stdout

	if ! test -d "$1"; then
		err "ERROR: '$1' is not a directory. git_remote_url must be called with the path to the top level source as the first argument'"
		return 1
	fi

	if test -z "$2"; then
		err "ERROR: git_remote_url must be called with a second argument that is the name of the remote"
		return 1
	fi

	local ret=0

	pushd "$1" >/dev/null

	local url=$(git remote get-url --push $2 2>&1) || ret=1

	popd >/dev/null

	if test "${ret}" -eq 0; then
		echo "${url}"
		return 0
	fi
}

function find_git_remote {
	# Arguments:
	#   $1 - Path to the top level Consul source
	#
	# Returns:
	#   0 - success
	#   * - error
	#
	# Note:
	#   The remote name to use for publishing will be echoed to stdout upon success

	if ! test -d "$1"; then
		err "ERROR: '$1' is not a directory. find_git_remote must be called with the path to the top level source as the first argument'"
		return 1
	fi

	need_url=$(normalize_git_url "${PUBLISH_GIT_HOST}:${PUBLISH_GIT_REPO}")
	debug "Required normalized remote: ${need_url}"

	pushd "$1" >/dev/null

	local ret=1
	for remote in $(git remote); do
		url=$(git remote get-url --push ${remote}) || continue
		url=$(normalize_git_url "${url}")

		debug "Testing Remote: ${remote}: ${url}"
		if test "${url}" == "${need_url}"; then
			echo "${remote}"
			ret=0
			break
		fi
	done

	popd >/dev/null
	return ${ret}
}

function git_remote_not_blacklisted {
	# Arguments:
	#   $1 - path to the repo
	#   $2 - the remote name
	#
	# Returns:
	#   0 - not blacklisted
	#   * - blacklisted
	return 0
}

function is_git_clean {
	# Arguments:
	#   $1 - Path to git repo
	#   $2 - boolean whether the git status should be output when not clean
	#
	# Returns:
	#   0 - success
	#   * - error
	#

	if ! test -d "$1"; then
		err "ERROR: '$1' is not a directory. is_git_clean must be called with the path to a git repo as the first argument'"
		return 1
	fi

	local output_status="$2"

	pushd "${1}" >/dev/null

	local ret=0
	test -z "$(git status --porcelain=v2 2>/dev/null)" || ret=1

	if is_set "${output_status}" && test "$ret" -ne 0; then
		err "Git repo is not clean"
		# --porcelain=v1 is the same as --short except uncolorized
		git status --porcelain=v1
	fi
	popd >/dev/null
	return ${ret}
}

function update_git_env {
	# Arguments:
	#   $1 - Path to git repo
	#
	# Returns:
	#   0 - success
	#   * - error
	#

	if ! test -d "$1"; then
		err "ERROR: '$1' is not a directory. is_git_clean must be called with the path to a git repo as the first argument'"
		return 1
	fi

	export GIT_COMMIT=$(git rev-parse --short HEAD)
	export GIT_DIRTY=$(test -n "$(git status --porcelain)" && echo "+CHANGES")
	export GIT_DESCRIBE=$(git describe --tags --always)
	export GIT_IMPORT=github.com/hashicorp/consul-k8s/version
	export GOLDFLAGS="-X ${GIT_IMPORT}.GitCommit=${GIT_COMMIT}${GIT_DIRTY} -X ${GIT_IMPORT}.GitDescribe=${GIT_DESCRIBE}"
	return 0
}

function git_push_ref {
	# Arguments:
	#   $1 - Path to the top level Consul source
	#   $2 - Git ref (optional)
	#   $3 - remote (optional - if not specified we will try to determine it)
	#
	# Returns:
	#   0 - success
	#   * - error

	if ! test -d "$1"; then
		err "ERROR: '$1' is not a directory. push_git_release must be called with the path to the top level source as the first argument'"
		return 1
	fi

	local sdir="$1"
	local ret=0
	local remote="$3"

	# find the correct remote corresponding to the desired repo (basically prevent pushing enterprise to oss or oss to enterprise)
	if test -z "${remote}"; then
		local remote=$(find_git_remote "${sdir}") || return 1
		status "Using git remote: ${remote}"
	fi

	local ref=""

	pushd "${sdir}" >/dev/null

	if test -z "$2"; then
		# If no git ref was provided we lookup the current local branch and its tracking branch
		# It must have a tracking upstream and it must be tracking the sanctioned git remote
		local head=$(git_branch "${sdir}") || return 1
		local upstream=$(git_upstream "${sdir}") || return 1

		# upstream branch for this branch does not track the remote we need to push to
		# basically this checks that the upstream (could be something like origin/main) references the correct remote
		# if it doesn't then the string modification wont apply and the var will reamin unchanged and equal to itself.
		if test "${upstream#${remote}/}" == "${upstream}"; then
			err "ERROR: Upstream branch '${upstream}' does not track the correct remote '${remote}' - cannot push"
			ret=1
		fi
		ref="refs/heads/${head}"
	else
		# A git ref was provided - get the full ref and make sure it isn't ambiguous and also to
		# be able to determine whether its a branch or tag we are pushing
		ref_out=$(git rev-parse --symbolic-full-name "$2" --)

		# -ne 2 because it should have the ref on one line followed by a line with '--'
		if test "$(wc -l <<<"${ref_out}")" -ne 2; then
			err "ERROR: Git ref '$2' is ambiguous"
			debug "${ref_out}"
			ret=1
		else
			ref=$(head -n 1 <<<"${ref_out}")
		fi
	fi

	if test ${ret} -eq 0; then
		case "${ref}" in
		refs/tags/*)
			status "Pushing tag ${ref#refs/tags/} to ${remote}"
			;;
		refs/heads/*)
			status "Pushing local branch ${ref#refs/tags/} to ${remote}"
			;;
		*)
			err "ERROR: git_push_ref func is refusing to push ref that isn't a branch or tag"
			return 1
			;;
		esac

		if ! git push "${remote}" "${ref}"; then
			err "ERROR: Failed to push ${ref} to remote: ${remote}"
			ret=1
		fi
	fi

	popd >/dev/null

	return $ret
}

function update_version {
	# Arguments:
	#   $1 - Path to the version file
	#   $2 - Version string
	#   $3 - PreRelease version (if unset will become an empty string)
	#
	# Returns:
	#   0 - success
	#   * - error

	if ! test -f "$1"; then
		err "ERROR: '$1' is not a regular file. update_version must be called with the path to a go version file"
		return 1
	fi

	if test -z "$2"; then
		err "ERROR: The version specified was empty"
		return 1
	fi

	local vfile="$1"
	local version="$2"
	local prerelease="$3"

	sed_i ${SED_EXT} -e "s/(Version[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\1\"${version}\"/g" -e "s/(VersionPrerelease[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\1\"${prerelease}\"/g" "${vfile}"
	return $?
}

function update_version_helm {
	# Arguments:
	#   $1 - Path to the directory where the root of the Helm chart is
	#   $2 - Version string
	#   $3 - Release version (if unset will become an empty string)
	#   $4 - Image base path
	#   $5 - Consul version string
	#   $6 - Consul image base path
	#   $7 - Consul-Dataplane version string
	#   $8 - Consul-Dataplane base path
	#
	# Returns:
	#   0 - success
	#   * - error

	if ! test -d "$1"; then
		err "ERROR: '$1' is not a directory. update_version_helm must be called with the path to the Helm chart"
		return 1
	fi

	if test -z "$2"; then
		err "ERROR: The version specified was empty"
		return 1
	fi

	local vfile="$1/values.yaml"
	local cfile="$1/Chart.yaml"
	local version="$2"
	local consul_version="$5"
	local prerelease="$3"
	local full_version="$2"
	local full_consul_version="$5"
	local full_consul_dataplane_version="$7"
	local consul_dataplane_base_path="$8"
	if ! test -z "$3" && test "$3" != "dev"; then
		full_version="$2-$3"
		full_consul_version="$5-$3"
		full_consul_dataplane_version="$7-$3"
	elif test "$3" == "dev"; then
		full_version="$2-$3"
		# strip off the last minor patch version so that the consul image can be set to something like 1.16-dev. The image
		# is produced by Consul every night
		full_consul_version="${5%.*}-$3"
		full_consul_dataplane_version="${7%.*}-$3"
	fi

	sed_i ${SED_EXT} -e "s/(imageK8S:.*\/consul-k8s-control-plane:)[^\"]*/imageK8S: $4${full_version}/g" "${vfile}"
	sed_i ${SED_EXT} -e "s/(version:[[:space:]]*)[^\"]*/\1${full_version}/g" "${cfile}"
	sed_i ${SED_EXT} -e "s/(appVersion:[[:space:]]*)[^\"]*/\1${full_consul_version}/g" "${cfile}"
	sed_i ${SED_EXT} -e "s/(image:.*\/consul-k8s-control-plane:)[^\"]*/image: $4${full_version}/g" "${cfile}"

	sed_i ${SED_EXT} -e "s,^( *image:)(.*/consul:)[^\"]*\$,\1 $6:${full_consul_version},g" ${cfile}
	sed_i ${SED_EXT} -e "s,^( *image:)(.*/consul:)[^\"]*\$,\1 $6:${full_consul_version},g" ${vfile}
	sed_i ${SED_EXT} -e "s,^( *image:)(.*/consul-enterprise:)[^\"]*\$,\1 $6:${full_consul_version},g" ${cfile}
	sed_i ${SED_EXT} -e "s,^( *image:)(.*/consul-enterprise:)[^\"]*\$,\1 $6:${full_consul_version},g" ${vfile}

	sed_i ${SED_EXT} -e "s/(imageConsulDataplane:.*\/consul-dataplane:)[^\"]*/imageConsulDataplane: ${consul_dataplane_base_path}:${full_consul_dataplane_version}/g" "${vfile}"
	sed_i ${SED_EXT} -e "s,^( *image:)(.*/consul-dataplane:)[^\"]*\$,\1 ${consul_dataplane_base_path}:${full_consul_dataplane_version},g" ${cfile}

	if test -z "$3"; then
		sed_i ${SED_EXT} -e "s/(artifacthub.io\/prerelease:[[:space:]]*)[^\"]*/\1false/g" "${cfile}"
	else
		sed_i ${SED_EXT} -e "s/(artifacthub.io\/prerelease:[[:space:]]*)[^\"]*/\1true/g" "${cfile}"
	fi
	return $?
}

function set_version {
	# Arguments:
	#   $1 - Path to top level Consul source
	#   $2 - The version of the release
	#   $3 - The release date
	#   $4 - The pre-release version
	#   $5 - The consul-k8s helm docker image base path
	#   $6 - The consul version
	#   $7 - The consul helm docker image base path
	#   $8 - The consul dataplane version
	#   $9 - The consul-dataplane helm docker image base path
	#
	#
	# Returns:
	#   0 - success
	#   * - error

	if ! test -d "$1"; then
		err "ERROR: '$1' is not a directory. prepare_release must be called with the path to a git repo as the first argument"
		return 1
	fi

	if test -z "$2"; then
		err "ERROR: The version specified was empty"
		return 1
	fi

	local sdir="$1"
	local vers="$2"
	local consul_vers="$6"
	local consul_dataplane_vers="$8"

	status_stage "==> Updating control-plane version/version.go with version info: ${vers} "$4""
	if ! update_version "${sdir}/control-plane/version/version.go" "${vers}" "$4"; then
		return 1
	fi

	status_stage "==> Updating cli version/version.go with version info: ${vers} "$4""
	if ! update_version "${sdir}/cli/version/version.go" "${vers}" "$4"; then
		return 1
	fi

	status_stage "==> Updating Helm chart version, consul-k8s: ${vers} "$4" consul: ${consul_vers} "$4" consul-dataplane: ${consul_dataplane_vers} "$4""
	if ! update_version_helm "${sdir}/charts/consul" "${vers}" "$4" "$5" "${consul_vers}" "$7" "${consul_dataplane_vers}" "$9"; then
		return 1
	fi

	return 0
}

function set_changelog {
	# Arguments:
	#   $1 - Path to top level Consul source
	#   $2 - Version
	#   $3 - Release Date
	#   $4 - The last git release tag
	#   $5 - Pre-release version
	#
	#
	# Returns:
	#   0 - success
	#   * - error

	# Check if changelog-build is installed
	if ! command -v changelog-build &>/dev/null; then
		echo "Error: changelog-build is not installed. Please install it and try again."
		exit 1
	fi

	local curdir="$1"
	local version="$2"
	local rel_date="$(date +"%B %d, %Y")"
	if test -n "$3"; then
		rel_date="$3"
	fi
	local last_release_date_git_tag=$4
        local preReleaseVersion="-$5"

	if test -z "${version}"; then
		err "ERROR: Must specify a version to put into the changelog"
		return 1
	fi

	if [ -z "$CONSUL_K8S_LAST_RELEASE_GIT_TAG" ]; then
		echo "Error: CONSUL_K8S_LAST_RELEASE_GIT_TAG not specified."
		exit 1
	fi

	cat <<EOT | cat - "${curdir}"/CHANGELOG.MD >tmp && mv tmp "${curdir}"/CHANGELOG.MD
## ${version}${preReleaseVersion} (${rel_date})
$(changelog-build -last-release ${CONSUL_K8S_LAST_RELEASE_GIT_TAG} \
		-entries-dir .changelog/ \
		-changelog-template .changelog/changelog.tmpl \
		-note-template .changelog/note.tmpl \
		-this-release $(git rev-parse HEAD))

EOT
}

function prepare_release {
	# Arguments:
	#   $1 - Path to top level Consul source
	#   $2 - The version of the release
	#   $3 - The release date
	#   $4 - The last release git tag for this branch (eg. v1.1.0)
  #   $5 - The consul version
	#   $6 - The consul-dataplane version
  #   $7 - The pre-release version
	#
	#
	# Returns:
	#   0 - success
	#   * - error

  local curDir=$1
  local version=$2
  local releaseDate=$3
  local lastGitTag=$4
  local consulVersion=$5
  local consulDataplaneVersion=$6
  local prereleaseVersion=$7

	echo "prepare_release: dir:${curDir} consul-k8s:${version} consul:${consulVersion} consul-dataplane:${consulDataplaneVersion} date:"${releaseDate}" git tag:${lastGitTag}"
	set_version "${curDir}" "${version}" "${releaseDate}" "${prereleaseVersion}" "hashicorp\/consul-k8s-control-plane:" "${consulVersion}" "hashicorp\/consul" "${consulDataplaneVersion}" "hashicorp\/consul-dataplane"
	set_changelog "${curDir}" "${version}" "${releaseDate}" "${lastGitTag}" "${prereleaseVersion}"
}

function prepare_dev {
	# Arguments:
	#   $1 - Path to top level Consul source
	#   $2 - The version of the release
	#   $3 - The release date
	#   $4 - The last release git tag for this branch (eg. v1.1.0) (Unused)
	#   $5 - The version of the next release
	#   $6 - The version of the next consul release
        #   $7 - The next consul-dataplane version
	#
	# Returns:
	#   0 - success
	#   * - error

  local curDir=$1
  local version=$2
  local releaseDate=$3
  local nextReleaseVersion=$5
  local nextConsulVersion=$6
  local nextConsulDataplaneVersion=$7

	echo "prepare_dev: dir:${curDir} consul-k8s:${nextReleaseVersion} consul:${nextConsulVersion} date:"${releaseDate}" mode:dev"
	set_version "${curDir}" "${nextReleaseVersion}" "${releaseDate}" "dev" "docker.mirror.hashicorp.services\/hashicorppreview\/consul-k8s-control-plane:" "${nextConsulVersion}" "docker.mirror.hashicorp.services\/hashicorppreview\/consul" "${nextConsulDataplaneVersion}" "docker.mirror.hashicorp.services\/hashicorppreview\/consul-dataplane"

	return 0
}

function git_staging_empty {
	# Arguments:
	#   $1 - Path to git repo
	#
	# Returns:
	#   0 - success (nothing staged)
	#   * - error (staged files)

	if ! test -d "$1"; then
		err "ERROR: '$1' is not a directory. commit_dev_mode must be called with the path to a git repo as the first argument'"
		return 1
	fi

	pushd "$1" >/dev/null

	declare -i ret=0

	for status in $(git status --porcelain=v2 | awk '{print $2}' | cut -b 1); do
		if test "${status}" != "."; then
			ret=1
			break
		fi
	done

	popd >/dev/null
	return ${ret}
}

function commit_dev_mode {
	# Arguments:
	#   $1 - Path to top level Consul source
	#
	# Returns:
	#   0 - success
	#   * - error

	if ! test -d "$1"; then
		err "ERROR: '$1' is not a directory. commit_dev_mode must be called with the path to a git repo as the first argument'"
		return 1
	fi

	status "Checking for previously staged files"
	git_staging_empty "$1" || return 1

	declare -i ret=0

	pushd "$1" >/dev/null

	status "Staging CHANGELOG.md and version_*.go files"
	git add CHANGELOG.md && git add */version/version*.go
	ret=$?

	if test ${ret} -eq 0; then
		status "Adding Commit"
		git commit -m "Putting source back into Dev Mode"
		ret=$?
	fi

	popd >/dev/null
	return ${ret}
}

function gpg_detach_sign {
	# Arguments:
	#   $1 - File to sign
	#   $2 - Alternative GPG key to use for signing
	#
	# Returns:
	#   0 - success
	#   * - failure

	# determine whether the gpg key to use is being overridden
	local gpg_key=${HASHICORP_GPG_KEY}
	if test -n "$2"; then
		gpg_key=$2
	fi

	gpg --default-key "${gpg_key}" --detach-sig --yes -v "$1"
	return $?
}

function shasum_directory {
	# Arguments:
	#   $1 - Path to directory containing the files to shasum
	#   $2 - File to output sha sums to
	#
	# Returns:
	#   0 - success
	#   * - failure

	if ! test -d "$1"; then
		err "ERROR: '$1' is not a directory and shasum_release requires passing a directory as the first argument"
		return 1
	fi

	if test -z "$2"; then
		err "ERROR: shasum_release requires a second argument to be the filename to output the shasums to but none was given"
		return 1
	fi

	pushd $1 >/dev/null
	shasum -a256 * >"$2"
	ret=$?
	popd >/dev/null

	return $ret
}

function ui_version {
	# Arguments:
	#   $1 - path to index.html
	#
	# Returns:
	#   0 - success
	#   * -failure
	#
	# Notes: echoes the version to stdout upon success
	if ! test -f "$1"; then
		err "ERROR: No such file: '$1'"
		return 1
	fi

	local ui_version=$(sed -n ${SED_EXT} -e 's/.*CONSUL_K8S_CONSUL_VERSION%22%3A%22([^%]*)%22%2C%22.*/\1/p' <"$1") || return 1
	echo "$ui_version"
	return 0
}
function ui_logo_type {
	# Arguments:
	#   $1 - path to index.html
	#
	# Returns:
	#   0 - success
	#   * -failure
	#
	# Notes: echoes the 'logo type' to stdout upon success
	# the 'logo' can be one of 'enterprise' or 'oss'
	# and doesn't necessarily correspond to the binary type of consul
	# the logo is 'enterprise' if the binary type is anything but 'oss'
	if ! test -f "$1"; then
		err "ERROR: No such file: '$1'"
		return 1
	fi
	grep -q "data-enterprise-logo" <"$1"

	if test $? -eq 0; then
		echo "enterprise"
	else
		echo "oss"
	fi
	return 0
}
