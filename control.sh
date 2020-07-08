git add .
git commit -m "$(date "+%Y-%m-%d %H:%M:%S") comment"
git push

echo "git push success"

hexo clean && hexo g && hexo d

echo "hexo deploy success"