for i in `ls /mnt/s3/`
do 
	if [ -f /mnt/s3/$i ]
 	then	 
		 dir=`echo -n $(grep To: /mnt/s3/$i | sed -e 's/To: //' | sed -e 's/\r//' | sed -e 's/\n//') | md5sum | cut -c 1-32`
		 if [ -d /mnt/s3/$dir/ ]
			then 
				mv /mnt/s3/$i /mnt/s3/$dir/
				chmod -R 755 /mnt/s3/$dir/
		 else 
			mkdir /mnt/s3/$dir
			mv /mnt/s3/$i /mnt/s3/$dir
			chmod -R 755 /mnt/s3/$dir/
		fi
	fi  
done

for i in `ls /tmp/generate_*`
do 
	hash=`echo $i | sed -e 's/\/tmp\/generate_//'`
	/usr/src/mail2pdf/mbox2pdf.pl --type s3mount --hash $hash --filename "$hash.pdf" 
	chmod 777 /tmp/"$hash.pdf"
	chown www-data:www-data /tmp/"$hash.pdf"
	rm $i
done
