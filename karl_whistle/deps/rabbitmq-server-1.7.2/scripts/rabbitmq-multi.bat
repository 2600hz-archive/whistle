@echo off
REM   The contents of this file are subject to the Mozilla Public License
REM   Version 1.1 (the "License"); you may not use this file except in
REM   compliance with the License. You may obtain a copy of the License at
REM   http://www.mozilla.org/MPL/
REM
REM   Software distributed under the License is distributed on an "AS IS"
REM   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
REM   License for the specific language governing rights and limitations
REM   under the License.
REM
REM   The Original Code is RabbitMQ.
REM
REM   The Initial Developers of the Original Code are LShift Ltd,
REM   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
REM
REM   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
REM   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
REM   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
REM   Technologies LLC, and Rabbit Technologies Ltd.
REM
REM   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
REM   Ltd. Portions created by Cohesive Financial Technologies LLC are
REM   Copyright (C) 2007-2010 Cohesive Financial Technologies
REM   LLC. Portions created by Rabbit Technologies Ltd are Copyright
REM   (C) 2007-2010 Rabbit Technologies Ltd.
REM
REM   All Rights Reserved.
REM
REM   Contributor(s): ______________________________________.
REM

setlocal

rem Preserve values that might contain exclamation marks before
rem enabling delayed expansion
set TDP0=%~dp0
set STAR=%*
setlocal enabledelayedexpansion

if "!RABBITMQ_BASE!"=="" (
    set RABBITMQ_BASE=!APPDATA!\RabbitMQ
)

if "!RABBITMQ_NODENAME!"=="" (
    set RABBITMQ_NODENAME=rabbit
)

if "!RABBITMQ_NODE_IP_ADDRESS!"=="" (
   if not "!RABBITMQ_NODE_PORT!"=="" (
      set RABBITMQ_NODE_IP_ADDRESS=0.0.0.0
   )
) else (
   if "!RABBITMQ_NODE_PORT!"=="" (
      set RABBITMQ_NODE_PORT=5672
   )
)

set RABBITMQ_PIDS_FILE=!RABBITMQ_BASE!\rabbitmq.pids
set RABBITMQ_SCRIPT_HOME=!TDP0!

if "!RABBITMQ_CONFIG_FILE!"=="" (
    set RABBITMQ_CONFIG_FILE=!RABBITMQ_BASE!\rabbitmq
)

if exist "!RABBITMQ_CONFIG_FILE!.config" (
    set RABBITMQ_CONFIG_ARG=-config "!RABBITMQ_CONFIG_FILE!"
) else (
    set RABBITMQ_CONFIG_ARG=
)

if not exist "!ERLANG_HOME!\bin\erl.exe" (
    echo.
    echo ******************************
    echo ERLANG_HOME not set correctly.
    echo ******************************
    echo.
    echo Please either set ERLANG_HOME to point to your Erlang installation or place the
    echo RabbitMQ server distribution in the Erlang lib folder.
    echo.
    exit /B
)

"!ERLANG_HOME!\bin\erl.exe" ^
-pa "!TDP0!..\ebin" ^
-noinput -hidden ^
!RABBITMQ_MULTI_ERL_ARGS! ^
-sname rabbitmq_multi ^
!RABBITMQ_CONFIG_ARG! ^
-s rabbit_multi ^
!RABBITMQ_MULTI_START_ARGS! ^
-extra !STAR!

endlocal
endlocal
