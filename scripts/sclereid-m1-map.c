#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/stat.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <errno.h>
#define SIZE 8294400
int main(void) {
    int fd=open("/mnt/frame",O_CREAT|O_RDWR|O_EXCL,0600);
    if(fd<0 || ftruncate(fd,SIZE)) {perror("create");return 1;}
    struct statx st={0};
    if(syscall(SYS_statx,fd,"",AT_EMPTY_PATH,STATX_BASIC_STATS,&st)) {perror("statx");return 1;}
    void *p=mmap(NULL,SIZE,PROT_READ|PROT_WRITE,MAP_SHARED_VALIDATE|MAP_SYNC,fd,0);
    printf("DAX=%d mask=%d MAP_SYNC=%s\n",!!(st.stx_attributes&STATX_ATTR_DAX),!!(st.stx_attributes_mask&STATX_ATTR_DAX),p==MAP_FAILED?strerror(errno):"ok");
    if(p==MAP_FAILED) p=mmap(NULL,SIZE,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(p==MAP_FAILED){perror("mmap");return 1;}
    puts("READY");fflush(stdout);
    unsigned seq,flush; uint64_t tag;
    while(scanf("%u %u %llu",&seq,&flush,(unsigned long long *)&tag)==3){
        memset(p,1+seq,SIZE);memcpy(p,&tag,8);__atomic_thread_fence(__ATOMIC_SEQ_CST);
        if(flush && msync(p,SIZE,MS_SYNC)){perror("msync");return 1;}
        printf("FRAME:%u\n",seq);fflush(stdout);
    }
}
