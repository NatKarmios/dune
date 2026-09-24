#!/bin/bash

version=e66a5e499ed11cbe6e02918fd73d8b544c9f7afb

set -e -o pipefail

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

pkg=perfetto

rm -rf $pkg
mkdir -p $pkg/src

(
    cd $TMP
    git clone https://github.com/NatKarmios/ocaml-perfetto.git $pkg
    cd $pkg
    git checkout $version
)

src=$TMP/$pkg

cp -v $src/src/perfetto.{ml,mli} $pkg/src/
cp -v $src/LICENSE $pkg/

git checkout $pkg/src/dune
git add -A .
