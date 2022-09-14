#!/bin/bash

display_usage() {
    cat <<EOT
Synchronize a (downstream) GIT repository with changes performed in another (upstream) GIT repository.

Usage: sync-cherry-pick.sh <downstream_org/repo/branch> --upstream <upstream_org/repo/branch> [options]

    --no-cherry-pick          Don't cherry pick the commits (will list them only)
-i, --interactive             Enable cherry pick interactive mode (useful to run from a local machine)
-u, --upstream                Upstream org/repository/branch from where to sync
-f, --force                   Clean any support files previously created
-h, --help                    This help message

EOT
}

# Directory where to temporarily store local repositories and other files
WORKSPACE="/tmp/"
 
UPSTREAM_ORG=""
UPSTREAM_REPO=""
UPSTREAM_BRANCH=""
UPSTREAM_REMOTE="upstream"
DOWNSTREAM_ORG=""
DOWNSTREAM_REPO=""
DOWNSTREAM_BRANCH=""
CHERRY_PICK="true"
FORCE="false"
INTERACTIVE="false"

main() {
  parse_args $@

  if [ ! -d .git ]; then
    echo "Not a GIT repo or not in the parent directory of the project. Make sure to run a checkout actions before running this action."
    exit -1
  fi;

  if [ $FORCE == "true" ]
  then
    # clean support files
    rm -f "${WORKSPACE}${UPSTREAM_REPO}-upstream.log" "${WORKSPACE}${DOWNSTREAM_REPO}-downstream.log" "${WORKSPACE}missing-downstream" "${WORKSPACE}missing-upstream"
  fi

  echo "🚜 adding $UPSTREAM_ORG/$UPSTREAM_REPO remote as $UPSTREAM_REMOTE"
  git remote add -f $UPSTREAM_REMOTE https://github.com/$UPSTREAM_ORG/$UPSTREAM_REPO.git

  # Check if the branches exist
 downstream_branch_exists=$(git branch -a | grep remotes/origin/$DOWNSTREAM_BRANCH)
  if [ "$downstream_branch_exists" == "" ]
  then
    echo "❗ the $DOWNSTREAM_BRANCH branch does not exist on $DOWNSTREAM_ORG/$DOWNSTREAM_REPO repository."
    echo "Make sure the downstream branch exists before retrying the synchronization process."
    exit -1
  fi

  upstream_branch_exists=$(git branch -a | grep remotes/$UPSTREAM_REMOTE/$UPSTREAM_BRANCH)
  if [ "$upstream_branch_exists" == "" ]
  then
    echo "❗ the $UPSTREAM_BRANCH branch does not exist on $UPSTREAM_ORG/$UPSTREAM_REPO repository."
    echo "Make sure the upstream branch exists before retrying the synchronization process."
    exit -1
  fi

  calculate_commits_upstream $UPSTREAM_REPO $UPSTREAM_REMOTE $UPSTREAM_BRANCH
  calculate_commits_downstream $DOWNSTREAM_REPO origin $DOWNSTREAM_BRANCH $UPSTREAM_ORG $UPSTREAM_REPO
  calculate_diff "$WORKSPACE${UPSTREAM_REPO}-upstream.log" "$WORKSPACE${DOWNSTREAM_REPO}-downstream.log" "${WORKSPACE}missing-downstream"
  calculate_diff "$WORKSPACE${DOWNSTREAM_REPO}-downstream.log" "$WORKSPACE${UPSTREAM_REPO}-upstream.log" "${WORKSPACE}missing-upstream"

  miss_downstream=$(grep -c ^ ${WORKSPACE}missing-downstream)
  miss_upstream=$(grep -c ^ ${WORKSPACE}missing-upstream)

  if [[ $miss_upstream != 0 ]]
  then
    echo "INFO: there are $miss_upstream commits diverged downstream - just an info, no action required"
  fi

  if [[ $miss_downstream == 0 ]]
  then
    echo "🍒 no upstream commits missing from downstream repo."
  else
    echo "INFO: there are $miss_downstream commits missing downstream."
    if [ "$CHERRY_PICK" == "true" ]
    then
      echo "INFO: I'll attempt to cherry-pick and sync. Keep tight!"
      # if this one fail, we must have someone to manually merge
      for i in `tac ${WORKSPACE}missing-downstream`
      do
        cherry_pick $i
      done
    else
      # Show the list only
      echo "🍒 list of commits not yet ported to downstream repo (sorted by time)"
      echo ""
      tac ${WORKSPACE}missing-downstream
    fi
  fi
}

parse_args(){
  if [ "$1" == "-h" ] || [ "$1" == "--help" ]
  then
    display_usage
    exit 0
  fi
  re="([^\/]+)\/([^\/]+)\/([^\/]+)"
  [[ "$1" =~ $re ]]
  DOWNSTREAM_ORG=${BASH_REMATCH[1]}
  DOWNSTREAM_REPO=${BASH_REMATCH[2]}
  DOWNSTREAM_BRANCH=${BASH_REMATCH[3]}
  if [ "$DOWNSTREAM_ORG" == "" ] || [ "$DOWNSTREAM_REPO" == "" ] || [ "$DOWNSTREAM_BRANCH" == "" ]
  then
    echo "❗ you must provide a downstream configuration as <org/repo/branch>"
    exit 1
  fi
  shift
  # Parse command line options
  while [ $# -gt 0 ]
  do
      arg="$1"

      case $arg in
        -h|--help)
          display_usage
          exit 0
          ;;
        -f|--force)
          FORCE="true"
          ;;
        --no-cherry-pick)
          CHERRY_PICK="false"
          ;;
        -i|--interactive)
          INTERACTIVE="true"
          ;;
        -u|--upstream)
          shift
          [[ "$1" =~ $re ]]
          UPSTREAM_ORG=${BASH_REMATCH[1]}
          UPSTREAM_REPO=${BASH_REMATCH[2]}
          UPSTREAM_BRANCH=${BASH_REMATCH[3]}

          if [ "$UPSTREAM_ORG" == "" ] || [ "$UPSTREAM_REPO" == "" ] || [ "$UPSTREAM_BRANCH" == "" ]
          then
            echo "❗ you must provide an upstream repo as -u <org/repo/branch>"
            exit 1
          fi
          ;; 
        *)
          echo "❗ unknown argument: $1"
          display_usage
          exit 1
          ;;
      esac
      shift
  done
}

calculate_commits_upstream(){
  repo=$1
  remote=$2
  branch=$3
  file="${WORKSPACE}${repo}-upstream.log"
  # For upstream, we can get a plain list of commit IDs
  echo "🔎 calculating list of upstream commits ($repo $remote/$branch)"
  git fetch $remote
  git checkout $remote/$branch
  git log --pretty=format:"%h" > "$file"
  printf "\n" >> "$file"
}

calculate_commits_downstream(){
  repo=$1
  remote=$2
  branch=$3
  upstream_org=$4
  upstream_repo=$5
  file="${WORKSPACE}${repo}-downstream.log"
  # For downstream, we need to extract the original commit id, if it was a cherry pick
  echo "🔎 calculating list of downstream commits ($remote/$branch)"
  git fetch $remote
  git checkout $remote/$branch
  for i in `git log --pretty=format:"%h"`
  do
    cherry_picked="false"
    commit_message=$(git rev-list --format=%s%b --max-count=1 $i | tail +2)
      while IFS= read -r line; do
        re="\(cherry picked from commit $upstream_org/$upstream_repo@([^\)]+)\)"
        [[ "$line" =~ $re ]]
        cherry_pick=${BASH_REMATCH[1]}
        if [[ ! -z "$cherry_pick" ]]; then
          cherry_picked="true"
          # Append the original commit id
          printf "$cherry_pick\n" >> "$file"
        fi
      done <<< "$commit_message"
    # Not cherry-picked, belong to the same tree
    if [ "$cherry_picked" == "false" ]
    then
      printf "$i\n" >> "$file"
    fi
  done
}

calculate_diff(){
  file1=$1
  file2=$2
  fileresult=$3

  touch $fileresult
  for commit in `cat $file1`
  do
    if [[ $(grep -c $commit $file2) == 0 ]]
    then
      printf "$commit\n" >> $fileresult
    fi
  done
}

cherry_pick(){
  commit="$1"
  # default for non-interactive, pick
  j="c"
  if [[ "$INTERACTIVE" == "true" ]] ; then
    git show $commit -s
    echo ""
    echo "What do you want to do? c) cherry-pick this commit, s) skip this commit definetely, l) leave this commit for later, q) quit process"
    read -n 1 j <&1
  fi
  if [[ "$j" == "q" ]] ; then
    exit 1
  elif [[ "$j" == "l" ]] ; then
    # skip this commit, will come back if the process is run again
    echo "Skipping for later"
  elif [[ "$j" == "s" ]] ; then
    # Add an empty commit referenced the upstream commit that we have just skipped (it won't be processed again in the future!)
    GIT_TITLE=$(git show --format=$'%s' -s $commit)
    git commit --allow-empty -m "skipped: $GIT_TITLE" -m "(cherry picked from commit $UPSTREAM_ORG/$UPSTREAM_REPO@$commit)"
  elif [[ "$j" == "c" ]] ; then
    # go ahead and cherry pick
    echo "🍒 cherry-picking $commit"
    git cherry-pick $commit
    if [[ $? != 0 ]]; then
      # default for non-interactive, quit
      k="q"
      if [[ "$INTERACTIVE" == "true" ]] ; then
        echo "Cannot merge... we have a conflict :("
        echo "What do you want to do? s) skip this commit definetely, l) leave this commit for later, q) quit process"
        read -n 1 k <&1
      fi
      if [[ "$k" == "q" ]] ; then
        # show how to manually fix the problem and quit the process
        show_how_to_fix  $UPSTREAM_ORG $UPSTREAM_REPO $DOWNSTREAM_ORG $DOWNSTREAM_REPO $DOWNSTREAM_REMOTE $DOWNSTREAM_BRANCH
      elif [[ "$k" == "l" ]] ; then
        # skip the commit in this process, will come back if the process is run again
        git cherry-pick --abort
      elif [[ "$k" == "s" ]] ; then
        # Add an empty commit referenced the upstream commit that we have just skipped (it won't be processed again in the future!)
        GIT_TITLE=$(git show --format=$'%s' -s $commit)
        git cherry-pick --abort
        git commit --allow-empty -m "skipped: $GIT_TITLE" -m "(cherry picked from commit $UPSTREAM_ORG/$UPSTREAM_REPO@$commit)"
      fi
    fi
    # mark this as cherry picked from upstream
    git commit --amend -m "$(git log --format=%B -n1)" -m "(cherry picked from commit $UPSTREAM_ORG/$UPSTREAM_REPO@$commit)"
  fi
}

show_how_to_fix(){
  UPSTREAM_ORG=$1
  UPSTREAM_REPO=$2
  DOWNSTREAM_ORG=$3
  DOWNSTREAM_REPO=$4
  DOWNSTREAM_REMOTE=$5
  DOWNSTREAM_BRANCH=$6

  echo "❗ Some conflict detected on commit $i. Sorry, I cannot do much more, please rerun with -i/--interactive or fix it manually."
  echo "Here a suggestion to help you fix the problem:"
  echo ""
  echo "  git clone https://github.com/$UPSTREAM_ORG/$UPSTREAM_REPO.git"
  echo "  cd $UPSTREAM_REPO"
  echo "  git remote add -f $DOWNSTREAM_REMOTE https://github.com/$DOWNSTREAM_ORG/$DOWNSTREAM_REPO.git"
  echo "  git checkout $DOWNSTREAM_REMOTE/$DOWNSTREAM_BRANCH"
  echo "  git cherry-pick $i"
  echo "  # FIX the conflict manually"
  echo "  git cherry-pick --continue"
  echo "  git commit --amend -m \"\$(git log --format=%B -n1)\" -m \"Conflict fixed manually\" -m \"(cherry picked from commit $UPSTREAM_ORG/$UPSTREAM_REPO@$i)\""
  echo "  git push $DOWNSTREAM_REMOTE HEAD:$DOWNSTREAM_BRANCH"
  echo ""
  echo "Notice that you must report the fixed resolution in a downstream commit appending the following message line: \"(cherry picked from commit $UPSTREAM_ORG/$UPSTREAM_REPO@$i)\""
  echo ""
  echo "NOTE: you may even provide a single empty commit adding the line \"(cherry picked from commit $UPSTREAM_ORG/$UPSTREAM_REPO@commit-hash)\" for each upstream commit manually fixed in the downstream repo. This last strategy can be used also as a workaround in the rare case you need to skip some commit from the syncronization process."
  exit 1
}

main $*
