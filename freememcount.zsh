#$PREFIX/bin/zsh

# 记录系统空闲内存信息到文本文件

freeoutcontent=($(free))
#echo ${(t)freeoutcontent}
memcontent=(${freeoutcontent[7,12]})
swapcontent=(${freeoutcontent[14,16]})
itemfree="$(date)\t$memcontent\t${memcontent[-1]}\t${swapcontent}\t${swapcontent[-1]}"
#print $itemfree
print $itemfree >> data/freeinfo.txt
