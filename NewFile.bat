@echo off
set /p filename=�������������ļ���:
if "%filename%"=="" exit
if /i "%filename:~-3%"==".md" (
    set fullfilename=%filename%
) else (
    set fullfilename=%filename%.md
)
echo ִ�����hugo new posts/%fullfilename%
hugo new posts/%fullfilename%
if exist content\posts\%fullfilename% (
    start "" content\posts\%fullfilename%
)
exit

