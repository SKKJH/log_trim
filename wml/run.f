set $filesize=128k
set $iosize=1m
set $meanappendsize=16k
set $runtime=300
define fileset name=bigfileset0,path=/media/nvme/filebench/set00,size=$filesize,entries=163840,dirwidth=20,prealloc=80
define process name=fileserverproc0,instances=1
{
  thread name=fileserverthread0,memsize=10m,instances=50
  {
    flowop createfile      name=createfile0,filesetname=bigfileset0,fd=1
    flowop writewholefile  name=wrtfile0,srcfd=1,fd=1,iosize=$iosize
    flowop closefile       name=closefile1_0,fd=1

    flowop openfile        name=openfile1_0,filesetname=bigfileset0,fd=1
    flowop appendfilerand  name=appendfilerand0,iosize=$meanappendsize,fd=1
    flowop closefile       name=closefile2_0,fd=1

    flowop openfile        name=openfile2_0,filesetname=bigfileset0,fd=1
    flowop readwholefile   name=readfile0,fd=1,iosize=$iosize
    flowop closefile       name=closefile3_0,fd=1

    flowop deletefile      name=deletefile0,filesetname=bigfileset0
    flowop statfile        name=statfile0,filesetname=bigfileset0
  }
}
echo "Custom multi-fileset fileserver personality loaded\n"
run $runtime
