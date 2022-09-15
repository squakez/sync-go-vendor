#!/bin/bash

set -e

if [[ "$1" == "" ]]; then
    echo "Please, provide a directory where your Go source code is stored, ie ./pkg/..."
    exit -1
fi;

if [ ! -d .git ]; then
    echo "Not a GIT repo or not in the parent directory of the project. Make sure to run a checkout actions before running this action."
    exit -2
fi

echo "🔄 refreshing vendor directory"
go mod vendor
go generate -mod=vendor $1
git add --all
git diff-index --quiet HEAD || git commit -m "Vendor directory refresh"