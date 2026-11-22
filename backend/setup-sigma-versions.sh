#!/bin/bash

# fetch 10 latest versions of sigma-cli
SIGMA_VERSIONS=$(curl -s https://pypi.org/pypi/sigma-cli/json | jq -r '.releases | keys | map(select(contains("rc") | not)) | .[-10:] | .[]')

# prepare virtualenv for each version
for VERSION in $SIGMA_VERSIONS; do
    # prepare folder to contain a single version
    mkdir $VERSION
    cp pyproject.toml uv.lock $VERSION
    cd $VERSION
    uv venv && uv -q pip sync pyproject.toml

    # fetch all plugins from plugin directory json and install latest compatible plugins available
    uv -q add sigma-cli==$VERSION
    curl https://raw.githubusercontent.com/SigmaHQ/pySigma-plugin-directory/refs/heads/main/pySigma-plugins-v1.json | jq '.plugins[].package' | xargs -n 1 uv add -q

    # remove if installed because of https://github.com/redsand/pySigma-backend-hawk/issues/1
    uv -q remove pySigma-backend-hawk

    # some problems with kusto backend, disable for older sigma versions
    if [[ $VERSION == 0.* ]]; then
        uv -q remove pySigma-backend-kusto
    fi

    # remove unused pyparsing imports in older version, see https://github.com/SigmaHQ/pySigma/pull/289#issuecomment-2410153076
    find ./ -iwholename "*sigma/conversion/base.py" -exec sed -i "/from pyparsing import Set/d" {} +
    find ./ -iwholename "*sigma/exceptions.py" -exec sed -i "/from pyparsing import List/d" {} +
    cd ..

    # Verify this version can actually run the backend, and drop it if not.
    #
    # Why this is needed: `uv add` resolves the WHOLE environment, so a single
    # incompatible plugin from the (unpinned, fetched-at-build-time) plugin
    # directory aborts the add and leaves the venv with only what
    # `uv pip sync pyproject.toml` installed. The result is a venv where
    # `import sigma` succeeds but sigma-cli is absent -- and backend.py calls
    # metadata.version("sigma-cli") at import time, so it raises
    # PackageNotFoundError, dies before binding its port, and
    # launch-backends.sh (which backgrounds each with `&` and checks nothing)
    # stays silent. frontend.py then lists the version purely from the
    # directory name and defaults to the newest, so EVERY conversion 500s with
    # "Connection refused" while `/` keeps returning 200 and the readiness
    # probe passes.
    #
    # That is exactly what shipped in sigma-converter:v14 (2026-11-18): sigma
    # 4.0.0 and 4.0.1 had both been released since the previous build, both
    # failed to resolve, and both were still advertised to users.
    if ./"$VERSION"/.venv/bin/python -c 'import importlib.metadata as m; m.version("sigma-cli")' >/dev/null 2>&1; then
        echo "  OK      sigma version $VERSION"
    else
        echo "  SKIPPED sigma version $VERSION -- sigma-cli did not install (dependency resolution aborted); removing so it is never advertised"
        rm -rf ./"$VERSION"
    fi
done

# Never ship an image with nothing that works. Without this the build happily
# succeeds on a directory of broken venvs.
USABLE=$(find . -maxdepth 1 -mindepth 1 -type d -not -name '.*' | wc -l | tr -d ' ')
echo "usable sigma versions: $USABLE"
if [ "$USABLE" -eq 0 ]; then
    echo "FATAL: no usable sigma versions were installed; refusing to build an image that cannot convert anything" >&2
    exit 1
fi
