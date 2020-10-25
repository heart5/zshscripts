#$PREFIX/bin/zsh
# 清除包含指定关键字词的进程

filename=$0
# $$ 当前脚本运行进程id；$# 传入的参数个数；$* 传入参数；$0 当前脚本启动命令；
print "$$\t$#\t$*\t$0\t${filename:t}" #提取路径中的文件名称

# zsh支持五种变量：整数、浮点数（bash不支持）、字符串、数组和哈希表（即字典）
# 变量用=号赋值，注意等号两端不能有空格
# 字符串赋值如果包含特殊字符，需要用引号括起来，双引号可以包含变量，单引号不可以
confirmed=false
keywords=$*
# if的判断条件用[]，注意必须加空格；判断符有eq（等于）、
if [ $# -eq 0 ];then
	# echo显示变量值，用print也可以
	echo "请明确需要杀死进程的关键字词，另外如确认要清除该关键字进程请参数尾部用confirm确认"
	exit 0
elif [ $# -gt 0 ];then
	# 无法直接取得最后一个元素，只好遍历之
	tmpkeywords=''
	for lastkey in $@; do 
		if [ $lastkey = 'confirm' ];then
			continue
		fi
		tmpkeywords=$tmpkeywords" "$lastkey
	done
	# 和python不同，lastkey在循环后没有被释放
	if [ $lastkey = 'confirm' ];then
		echo "操作已确认，将被真实执行"
		keywords=$tmpkeywords
		confirmed=true
	fi
	# 截取字符串的一部分用[]
	print "最后一个参数为：\t${lastkey[0,-1]}"
	targetcontent=$(ps -efww|grep $keywords|grep -v grep|grep -v $filename|cut -c 9-15,49-)
	# 用双引号的方式echo，用管道再起线程才能识别字符串中的回车
	# 声明数组变量
	targetconlst=()
	echo "$targetcontent" | while read i
	do
		# 数组追加元素的方式
		targetconlst+=("$i")
	done
	# 显示变量的数据类型
	#echo ${(t)targetconlst}
	# 数组长度默认是1？？？处理之
	# 数值运算可以用反引号`包括，还需要关键词expr
	#targetlen=`expr ${#targetconlst[@]} - 1`
	targetlen=${#targetconlst[@]}

	# 数值比较可以用双括号
	if (( $targetlen == 1 )); then
		# 数值运算也可以用双括号，双括号中变量的$可加可不加
		#targetlen=$(($targetlen - 1))
		targetlen=$((targetlen - 1))
	fi
	if [ $targetlen -gt 1 ];then
		echo "待处理关键字词为：	$keywords"
		# 声明变量类型，默认是字符串而不是数值
		integer i=0
		# zsh对包含回车的字符串数组遍历时目前仅发现while语句能有效取出，for百般不行
		while (($i < $targetlen)){
			print ${targetconlst[$i]}
			i+=1
		}
	else
		echo "没有找到包含关键字$keywords的进程，退出！"
		exit 0
	fi
	echo "找到的进程数量为：	$targetlen" 
fi

if $confirmed;then
	integer ii=0
	while (($ii < $targetlen)){
		psinfo="${targetconlst[$ii]}"
		pid=$(echo "$psinfo" | cut -d ' ' -f 1)
		#print ${(t)pid}
		if [ $pid = $$ ];then
			continue
		fi
		print "\n*****&&&*****"
		echo $psinfo
		echo "清除id为$pid的进程……"
		kill -9 $pid
		print "\x0d\bDone！"
		ii+=1
	}
	print "………………………………………………\n处理的进程数量为：	$ii" 
fi

# zsh对于包含回车的字符串数组处理很迷惑，for只能取出首行，如果不加双引号输出的甚至只是单词
#if $confirmed;then
	#print ${(t)targetconlst}
	#for psinfo ("$targetconlst"){
		#print "$psinfo"
	#}
#fi

if [ $? = 0 ];then
	echo "运行成功！"
fi

