#$PREFIX/bin/zsh

# 记录系统空闲内存信息到文本文件
# 命令：freememcount.zsh [convert]
# convert参数用于转换记录格式
# Thu Oct 29 18:52:00 CST 2020	11782032	2914804	0	0
# 1603981920	25	0	0

# 定义数据文件名
datafile='data/freeinfo.txt'
#echo $datafile

# $(free)执行free命令并返回值，再加一层括号使返回值数组化（用空格分隔）
freeoutcontent=($(free))
#echo ${(t)freeoutcontent}
#echo ${#freeoutcontent[*]}
# 取mem字符串并括起来再次形成数组
memcontent=(${freeoutcontent[7,12]})
# 取swap字符串必能括起来再次形成数组
swapcontent=(${freeoutcontent[14,16]})

# 指定数值类型为浮点数float，否则默认是整数类型
float totalmemo=$((${memcontent[0]}))
float freememo=$((${memcontent[-1]}))
# 调用zsh的数学计算模块，这里就是用到了int
zmodload -i zsh/mathfunc
# 数值计算方式$(( $var1 * $var2 ))
percent=$(($freememo * 100 / $totalmemo ))
print $(( int($percent) ))
# 装配待输出的成型字符串，用\t分隔
itemfree="$(date "+%s")\t$(( int($percent) ))\t${swapcontent}\t${swapcontent[-1]}"
#print $itemfree
zmodload -i zsh/mapfile
# 判断文件是否存在的语句：${+mapfile[$datafile]}
if !((${+mapfile[$datafile]})); then
	print "totalmemo="$(( int($totalmemo) )) > $datafile
fi
# if {}的语法格式5.8版本不支持
#if ![[${+mapfile[$datafile]}]] {
	#print "totalmemo="$totalmemo > $datafile
#}
print $itemfree >> $datafile

# 查看首行是否有总内存信息，没有就添加到相应信息到首行
specline=${"$(<$datafile)"[(f)0]}
# 查看首行是否包含内存总量信息（用=判断），没有就插入并附上原本的其它信息
# **字符串查找**${targetstr[(i)sonstr]}，i是从左到右，I是从右到左，没有找到就返回目标字符串长度
if [ ${#specline} == ${specline[(i)\=]} ]; then
	# 用printf指定%d显示整数，否则就用科学计数显示了，不直观；另外，末尾加转义符\n换行，默认是不会自动换行的
	printf "totalmemo=%d\n" $totalmemo > $datafile

	# 按行读取文件内容到数组变量中
	fileconarray=(${(f)"$(<$datafile)"})
	# 用变量存储行数的价值在于提高后面循环的效率，避免多次运算
	linescount=${#fileconarray[*]}
	echo $linescount
	integer ii=0
	while (( $ii < $linescount )){
		print "${fileconarray[$ii]}" >> $datafile
		ii+=1
	}
fi

# 接收convert命令，把记录的长文本该是转换为短短的数据格式
# 字典需要先进行定义
typeset -A monthdict
monthdict=(Oct 10 Dec 11 Nov 12 Jan 01 Feb 02 Mar 03 Apr 04 May 05 Jun 06 Jul 07 Aug 08 Sep 09)
if [[ $1 == 'convert' ]]; then
	# 数据信息纵览
	fileconarray=(${(f)"$(<$datafile)"})
	if [ ${#fileconarray[*]} != 0 ]; then
		print "读入的文件内容所存储变量类型为：\t"${(t)fileconarray}
		print "首行（其实是数组第一个item）内容为：\t$fileconarray，长度为：\t"${#fileconarray}
		print "行数（即数组内item数量）为：\t"${#fileconarray[*]}
		print "数据item示例：\t${fileconarray[-1]}"
	else
		exit 0
	fi

	# 处理长文本
	integer linescount=${#fileconarray[*]}
	datafilebak='data/freeinfo_bak.txt'
	integer ii=0
	specline=${"$(<$datafile)"[(f)0]}
	if [ ${#specline} > ${specline[(i)\=]} ]; then
		print "${specline}" > $datafilebak
		linescount=$(( linescount - 1 ))
		ii+=1
	fi
	echo $linescount
	while (( $ii <= $linescount )){
		linecontent=(${fileconarray[ii]})
		echo ${linecontent[*]}
		if [ ${#linecontent[*]} != 10 ]; then
			ii+=1
			continue
		fi
		tdsa=(${linecontent[0,5]})
		timestr="${tdsa[-1]}-${monthdict[${tdsa[1]}]}-${tdsa[2]} ${tdsa[3]}"
		# 指定数值类型为浮点数float，否则默认是整数类型
		float totalmemo=$((${linecontent[6]}))
		float freememo=$((${linecontent[7]}))
		# 数值计算方式$(( $var1 * $var2 ))
		percent=$(($freememo * 100 / $totalmemo ))
		print $(date --date="$timestr" "+%s")"\t$(( int($percent) ))\t${linecontent[8]}\t${linecontent[9]}" >> $datafilebak
		ii+=1
	}
fi


