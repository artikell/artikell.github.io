case $1 in
    "commit")
        git add .
        git commit -m "$(date "+%Y-%m-%d %H:%M:%S") comment"
        git push

        echo "git push success"

        hexo clean && hexo g && hexo d

        echo "hexo deploy success"
        ;;
    "server")
        hexo g && hexo s
        ;;
esac