@echo off

REM Don't export variables
setlocal

REM Script directory
SET SCRIPT_DIR=%~dp0

REM Project directory
PUSHD .
CD "%SCRIPT_DIR%\.."
SET PROJECT_DIR=%CD%
POPD

docker volume create jekyll
docker run ^
    -v "%PROJECT_DIR%:/srv/jekyll" -p 4000:4000 ^
    -v "jekyll:/usr/local/bundle" ^
    --rm -it jekyll/jekyll bash

REM jekyll serve -D
