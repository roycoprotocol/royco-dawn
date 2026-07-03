#!/bin/sh

git apply --whitespace=nowarn certora/munge.diff
git apply certora/absolutePaths.diff
