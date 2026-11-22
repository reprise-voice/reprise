#!/bin/bash
## sets up the docs environment to serve mkdocs-built site

pushd $(dirname $0) > /dev/null

cd $(pwd -P)/..
DOCS_ROOT=`cd ./doc/mkdocs && pwd -P`

if [ -z `command -v cpio` ] ; then
    echo "cpio command is not available, please install it" && popd > /dev/null && exit 1
fi

find {scripts,doc,core,applications} -type f -path "doc/mkdocs*" -prune -o -path "*/doc/ref/*" -prune -o -regex ".+\.\(md\|png\|jpg\|svg\|json\|ini\|mk\|hrl\)$" -print | cpio -p -dum --quiet $DOCS_ROOT/docs

## the READMEs of the image, module and configuration directories, and the
## project files at the root (not README.md, which would collide with the
## site's index.md), which the curated navigation in dev_header_yml names
for dir in docker freeswitch configs tools deploy; do
    [ -d "$dir" ] && find "$dir" -type f -name "*.md" -print | cpio -p -dum --quiet $DOCS_ROOT/docs
done
ls CHANGELOG.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md 2>/dev/null | cpio -p -dum --quiet $DOCS_ROOT/docs

popd > /dev/null
