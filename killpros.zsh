#!/data/data/com.termux/files/usr/bin/zsh

# 清除包含指定关键字词的进程。关键词用空格分开可以被分别处理。命令行尾部参数如果是confirm则确认执行，否则仅展示查找的进程结果。

prtsplitline(){
	print "***************我是长长久久的分割线*****************\n"
}

killpro4onekey() {
	targetcontent=$(ps -efww|grep $1|grep -v grep|grep -v $filename|cut -c 9-15,49-)
	# 用双引号的方式echo，用管道再起线程才能识别字符串中的回车
	# 声明数组变量
	#echo ${(t)targetcontent} ${#targetcontent} 
	#echo ${targetcontent[*]}
	if [[ ${#targetcontent} == 0 ]];then
		echo "很遗憾，没有找到包含关键字$1的进程！"
		prtsplitline
		return
	fi
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
	targetlen=${#targetconlst}

	# 数值比较可以用双括号
	#if (( $targetlen == 1 )); then
		## 数值运算也可以用双括号，双括号中变量的$可加可不加
		##targetlen=$(($targetlen - 1))
		#targetlen=$((targetlen - 1))
	#fi
	#echo $targetlen
	if [ $targetlen -gt 0 ];then
		print "正在处理的关键字词为：	$1\n"
		# 声明变量类型，默认是字符串而不是数值
		integer i=1
		# zsh对包含回车的字符串数组遍历时目前仅发现while语句能有效取出，for百般不行
		while (($i <= $targetlen)){
			print ${targetconlst[$i]}
			i+=1
		}
	fi
	echo "找到的进程数量为：	$targetlen" 

	if $confirmed;then
		integer ii=1
		while (($ii <= $targetlen)){
			psinfo="${targetconlst[$ii]}"
			pid=$(echo "$psinfo" | cut -d ' ' -f 1)
			#print ${(t)pid}
			if [ $pid = $$ ];then
				continue
			fi
			print "*****&&&*****"
			echo $psinfo
			echo "清除id为$pid的进程……"
			kill -9 $pid
			print "\x0d\bDone！"
			ii+=1
		}
		ii=ii-1
		print "………………………………………………\n处理的进程数量为：	$ii" 
	fi
	prtsplitline

}


filename=$0
# $$ 当前脚本运行进程id；$# 传入的参数个数；$* 传入参数；$0 当前脚本启动命令；
print "$$\t$#\t$*\t$0\t${filename:t}" #提取路径中的文件名称

# zsh支持五种变量：整数、浮点数（bash不支持）、字符串、数组和哈希表（即字典）
# 变量用=号赋值，注意等号两端不能有空格
# 字符串赋值如果包含特殊字符，需要用引号括起来，双引号可以包含变量，单引号不可以
confirmed=false
# 字符串转数组直接用括号括起来，字符串需要是用空格分隔的词
args=($*)
print "输入的参数（\$*）“$*”括号()括起来后（args=(\$*)）的类型为：\t${(t)args}，长度为：\t${#args[@]}；print \$args[1]则仅显示第一个参数值：$args[1]，print \${args[*]}才能显示全部参数（${args[*]}）"
# 数组变量赋值给其它变量也要显示全部要素并括起来，其实就是重构了一次
keywords=(${args[@]})
#print ${keywords[@]}
#print ${(t)keywords}
#print ${#keywords[@]}
## if的判断条件用[]，注意必须加空格；判断符有eq（等于）、
if [ $# -eq 0 ];then
	# echo显示变量值，用print也可以
	echo "请明确需要杀死进程的关键字词，另外如确认要清除该关键字进程请参数尾部用confirm确认"
	exit 0
elif [ $# -gt 0 ];then
	lastkey=${keywords[-1]} 
	print ${(t)lastkey} $lastkey
	if [[ $lastkey == 'confirm' ]];then
		echo "操作已确认，将被真实执行"
		# 数组变量赋值蜜汁操作，括号括起来；如果不加括号，默认替换被赋值数组的第一个元素值
		keywords=(${args[0,-2]})
		confirmed=true
	fi
	# 截取字符串的一部分用[]，从0开始计数
	print "最后一个参数为：\t${lastkey[1,-1]}"
fi

print "\n"
for kw (${keywords[*]}){
	killpro4onekey $kw
}

#if $confirmed;then
	#print ${(t)targetconlst}
	#for psinfo ("$targetconlst"){
		#print "$psinfo"
	#}
#fi

if [ $? = 0 ];then
	echo "运行完毕！"
fi

