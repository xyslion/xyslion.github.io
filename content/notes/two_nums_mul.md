---
title: "两个大数字符串的乘积"
date: 2019-10-11T12:40:22+08:00
slug: two_nums_mul
tags: ["algorithm"]
categories: ["algorithm"]
---

## 题目

给定两个以字符串形式表示的非负整数 num1 和 num2，返回 num1 和 num2 的乘积，它们的乘积也表示为字符串形式。  
示例 1:  
输入: num1 = "2", num2 = "3"输出: "6"  
示例 2:  
输入: num1 = "123", num2 = "456"输出: "56088"  
说明：  
    * num1 和 num2 的长度小于110。  
    * num1 和 num2 只包含数字 0-9。 
    * num1 和 num2 均不以零开头，除非是数字 0 本身。  
    * 不能使用任何标准库的大数类型（比如 BigInteger）或直接将输入转换为整数来处理。  

## 解题思路

模拟竖式乘法， 如下图  
![](https://github.com/xyslion/blog/raw/master/static/media/two_number_mul.png)

代码实现：    
```go
package mul

import (
    "strconv"
)

func multiply(num1 string, num2 string) string {
    if num1 == "0" || num2 == "0" {
        return "0"
    }
    n1l := len(num1)
	n2l := len(num2)
	arrInt := make([]int, n1l+n2l)
	for i := n1l - 1; i >= 0; i-- {
		n1 := int(num1[i] - '0')
		for j := n2l - 1; j >= 0; j-- {
			n2 := int(num2[j] - '0')
			sum := n1*n2 + arrInt[i+j+1]
			arrInt[i+j+1] = sum % 10
			arrInt[i+j] += sum / 10
		}
	}

	fz := true
	ret := ""
	for i := 0; i < len(arrInt); i++ {
		if arrInt[i] == 0 && fz {
			continue
		}
		fz = false
		ret = ret + strconv.Itoa(arrInt[i])
	}
	return ret
}
```