@echo off
set /p filename=请输入新文章文件名:
if "%filename%"=="" exit
if /i "%filename:~-3%"==".md" (
    set fullfilename=%filename%
) else (
    set fullfilename=%filename%.md
)
echo 执行命令：hugo new posts/%fullfilename%
hugo new posts/%fullfilename%
if exist content\posts\%fullfilename% (
    start "" content\posts\%fullfilename%
)
exit

