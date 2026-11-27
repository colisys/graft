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
#include <time.h>
#include <emmintrin.h>
#include <poll.h>
#include <sys/timerfd.h>
#include <sys/prctl.h>
#define SIZE 8294400
static long long now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) exit(1);
    return t.tv_sec * 1000000000LL + t.tv_nsec;
}

static int traced;
static void setting(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_TRUNC);
    if (fd < 0 || write(fd,value,strlen(value)) != (ssize_t)strlen(value) || close(fd)) { perror(path); exit(1); }
}

static void publish(char *p, unsigned count, unsigned size, unsigned first, unsigned lead_us, unsigned slack_ns) {
    if (lead_us > 4000 || !count || (size != SIZE && size != 262144)) exit(1);
    long inherited = prctl(PR_GET_TIMERSLACK);
    if (inherited <= 0 || (slack_ns && prctl(PR_SET_TIMERSLACK, (unsigned long)slack_ns))) exit(1);
    long effective = prctl(PR_GET_TIMERSLACK);
    if (effective != (slack_ns ? (long)slack_ns : inherited)) exit(1);
    int timer = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC);
    if (timer < 0) exit(1);
    unsigned busy[2] = {0}, i = 0, sent = 0, expired = 0, blocked = 0;
    long long misses[600][4];
    if (traced) {
        if (count > 600) exit(1);
        setting("trace", "\n"); setting("tracing_on", "1");
    }
    long long ticks[2], origin = now() + 1000000;
    while (i < count || busy[0] || busy[1]) {
        long long tick = origin + i * 1000000000LL / 60;
        long long target = tick - lead_us * 1000LL;
        struct itimerspec alarm = {.it_value = {target / 1000000000, target % 1000000000}};
        long long arm = traced ? now() : 0;
        if (i < count && timerfd_settime(timer, TFD_TIMER_ABSTIME, &alarm, NULL)) exit(1);
        struct pollfd fds[] = {{0,POLLIN,0},{i < count ? timer : -1,POLLIN,0}};
        if (poll(fds, 2, 10000) <= 0) exit(1);
        if (fds[0].revents) {
            char line[80]; unsigned slot, seq;
            if (!fgets(line,sizeof line,stdin) || sscanf(line,"K %u %u",&slot,&seq)!=2 || slot>1 || !seq || busy[slot]!=seq) exit(1);
            long long handled = now();
            printf("E:%u %lld %lld\n",seq,handled-ticks[slot],handled); fflush(stdout);
            busy[slot]=0;
        }
        if (!fds[1].revents) continue;
        uint64_t fired;
        if (read(timer,&fired,sizeof fired)!=sizeof fired) exit(1);
        unsigned slot = busy[0] ? 1 : 0;
        long long wake = now();
        while (lead_us && wake < tick) {
            _mm_pause();
            wake = now();
        }
        if (wake >= origin + (i+1LL)*1000000000/60) {
            if (traced) {
                misses[expired][0]=i; misses[expired][1]=tick;
                misses[expired][2]=arm; misses[expired][3]=wake;
            }
            expired++;
        }
        else if (busy[slot]) blocked++;
        else {
            unsigned seq = first + sent++, offset = (i % (SIZE/size))*size;
            char *dest = p + slot*SIZE + offset;
            uint64_t tag = seq;
            long long start = now();
            if (size == SIZE) {
                __m128i v = _mm_set1_epi8(1 + seq % 255);
                for (unsigned j=0;j<size;j+=16) _mm_stream_si128((__m128i *)(dest+j),v);
                _mm_sfence();
            } else memset(dest,1+seq%255,size);
            memcpy(dest,&tag,8); __atomic_thread_fence(__ATOMIC_SEQ_CST);
            long long end = now();
            busy[slot]=seq; ticks[slot]=tick;
            printf("F:%u %u %u %lld %lld %lld\n",seq,i,slot,wake-tick,end-start,end); fflush(stdout);
        }
        i++;
    }
    if (traced) {
        setting("tracing_on", "0");
        for (unsigned j=0;j<expired;j++) printf("X:%d %lld %lld %lld %lld\n",getpid(),misses[j][0],misses[j][1],misses[j][2],misses[j][3]);
    }
    close(timer);
    if (slack_ns && (prctl(PR_SET_TIMERSLACK, (unsigned long)inherited) || prctl(PR_GET_TIMERSLACK) != inherited)) exit(1);
    printf("D:%u %u %u %ld\n",sent,expired,blocked,effective);
}

int main(int argc, char **argv) {
    int ring = argc == 2 && !strcmp(argv[1], "ring");
    unsigned capacity = ring ? 2 * SIZE : SIZE;
    int fd=open("/mnt/frame",O_CREAT|O_RDWR|O_EXCL,0600);
    if(fd<0 || ftruncate(fd,capacity)) {perror("create");return 1;}
    struct statx st={0};
    if(syscall(SYS_statx,fd,"",AT_EMPTY_PATH,STATX_BASIC_STATS,&st)) {perror("statx");return 1;}
    void *p=mmap(NULL,capacity,PROT_READ|PROT_WRITE,MAP_SHARED_VALIDATE|MAP_SYNC,fd,0);
    printf("DAX=%d mask=%d MAP_SYNC=%s\n",!!(st.stx_attributes&STATX_ATTR_DAX),!!(st.stx_attributes_mask&STATX_ATTR_DAX),p==MAP_FAILED?strerror(errno):"ok");
    if(p==MAP_FAILED) p=mmap(NULL,capacity,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(p==MAP_FAILED){perror("mmap");return 1;}
    traced = getenv("TRACE_TICKS") != NULL;
    if (traced) {
        char filter[96];
        if (chdir("/sys/kernel/tracing")) return 1;
        setting("tracing_on","0"); setting("trace_clock","mono"); setting("buffer_size_kb","4096");
        snprintf(filter,sizeof filter,"common_pid == %d",getpid()); setting("events/timer/hrtimer_start/filter",filter);
        snprintf(filter,sizeof filter,"pid == %d",getpid()); setting("events/sched/sched_wakeup/filter",filter);
        snprintf(filter,sizeof filter,"next_pid == %d || prev_pid == %d",getpid(),getpid()); setting("events/sched/sched_switch/filter",filter);
        setting("events/timer/hrtimer_start/enable","1"); setting("events/timer/hrtimer_expire_entry/enable","1");
        setting("events/sched/sched_wakeup/enable","1"); setting("events/sched/sched_switch/enable","1");
    }
    puts("READY");fflush(stdout);
    if (ring || (argc == 2 && !strcmp(argv[1], "paced"))) {
        setvbuf(stdin,NULL,_IONBF,0);
        char line[256];
        while (fgets(line, sizeof line, stdin)) {
            unsigned seq, offset, length;
            unsigned long long tag;
            int stream = ring && line[0] == 'S';
            unsigned lead_us = 0, slack_ns = 0;
            if (traced && !strcmp(line,"TRACE\n")) {
                FILE *f=fopen("trace","r"); char row[1024];
                if (!f) return 1;
                while (fgets(row,sizeof row,f)) fputs(row,stdout);
                if (ferror(f) || fclose(f)) return 1;
                puts("END");
            } else if (ring && sscanf(line,"G %u %u %u %u %u",&seq,&offset,&length,&lead_us,&slack_ns)>=3) {
                publish(p,seq,offset,length,lead_us,slack_ns);
            } else if ((stream || line[0] == 'W') && sscanf(line+1, " %u %u %u %llu", &seq, &offset, &length, &tag) == 4) {
                if (length < 8 || offset >= capacity || length > SIZE - offset % SIZE) return 1;
                struct timespec start, end;
                if (ring && clock_gettime(CLOCK_MONOTONIC, &start)) return 1;
                if (stream) {
                    if (length != SIZE || offset % SIZE) return 1;
                    __m128i v = _mm_set1_epi8(1 + seq % 255);
                    for (unsigned i = 0; i < length; i += 16)
                        _mm_stream_si128((__m128i *)((char *)p + offset + i), v);
                    _mm_sfence();
                } else memset((char *)p + offset, 1 + seq % 255, length);
                memcpy((char *)p + offset, &tag, 8);
                __atomic_thread_fence(__ATOMIC_SEQ_CST);
                if (ring) {
                    if (clock_gettime(CLOCK_MONOTONIC, &end)) return 1;
                    printf("FRAME:%u %lld\n", seq, (long long)(end.tv_sec-start.tv_sec)*1000000000 + end.tv_nsec-start.tv_nsec);
                } else printf("FRAME:%u\n", seq);
            } else if (sscanf(line, "P %u", &seq) == 1) {
                printf("PONG:%u\n", seq);
            } else if (!strcmp(line, "CPU\n")) {
                struct timespec ts;
                if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)) return 1;
                printf("CPU:%llu\n", (unsigned long long)ts.tv_sec * 1000000000 + ts.tv_nsec);
            } else {
                return 1;
            }
            fflush(stdout);
        }
        return ferror(stdin) != 0;
    }
    unsigned seq,flush; unsigned long long tag;
    while(scanf("%u %u %llu",&seq,&flush,&tag)==3){
        memset(p,1+seq,SIZE);memcpy(p,&tag,8);__atomic_thread_fence(__ATOMIC_SEQ_CST);
        if(flush && msync(p,SIZE,MS_SYNC)){perror("msync");return 1;}
        printf("FRAME:%u\n",seq);fflush(stdout);
    }
}
