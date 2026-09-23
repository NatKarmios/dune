#!/bin/bash

version=35ad12c4dcca44b313f81efe7af77f2f5b004dac

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
