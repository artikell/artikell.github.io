# 存储管理

## Linux 内存管理框架

通过页面目录和页面表分为2个层次实现线性地址到物理地址的映射。但这类设计只能针对32位操作系统，因为每个页面大小为4k。

于是针对当前情况，linux设计了3层结构：PGD,PMD,PT。
而PTE是page table entry，表项结构体。PT是PTE的大数组，PMD和PGD则是PT的映射表。

```
typedef struct {
unsigned int ptba:20; /* 页表基地址的高20位  */
unsigned int avail:3; /*   */
unsigned int g:1; /* 是否为全局性页面  */
unsigned int ps:1; /* 页面大小  */
unsigned int reserved:1; /*   */
unsigned int a:1; /* 已经被访问过  */
unsigned int pcd:1; /* 关闭缓冲存储器  */
unsigned int pwt:1; /* 用于缓冲存储器  */
unsigned int u_s:1; /* 用户权限还是系统权限  */
unsigned int r_w:1; /* 只读或可写  */
unsigned int p:1; /* 0表示不在内存中  */
}
```

![](2020-1-12-22-46-27.jpg)

虚拟Linux内存管理通过四部完成地址转换：
1. 用线性地址的最高一个位段从PGD找到对应PMD表项
2. 第二个位段从PMD中找到对应PT表项
3. 第三个位段从PT中找到对应的PTE，指向物理页面的指针
4. 线性地址中最后位段为相对偏移量

这其中有个重点问题，在cpu和mmu的机制中，只存在2层模型，所以需要将三层映射支持两层结构中。同时在后期Intel中引入了PAE扩充功能，允许地址宽度提高至36位，在硬件方面支持了三层映射模型。

三层模型支持两层模型流程：
1. 内核为MMU设置好映射的PGD，通过位段找到对应的中间目录
2. 而PMD设置为0，所以PGD直接映射到PT中。
3. MMU找到PT目录中找到对应的PTE
4. 最终和偏移量进行组合得到物理地址

![虚拟地址、线性地址、物理地址的关系](2020-1-12-23-50-09.jpg)

GDT和LDT，2者名字分别为全局段描述符和局部段描述符。

GDT的容量有多大？GDT位段总共13位，共计8192个描述项，而每个进程存在2个表项，所以，理论上系统最大进程数为4090

然后，每个描述表项含有段的基地址和段的大小，再加上其他一些信息，共计8个字节。
```
typedef struct {
 unsigned int base24_31:8; /* 基地址的高8位 */
 unsigned int g:1;  
 unsigned int d_b:1;  
 unsigned int unused:1; 
 unsigned int avl:1;    
 unsigned int seg_limit_16_19:4;     /* 段长度的高4位 */
 unsigned int p:1;  
 unsigned int dpl:2;  
 unsigned int s:1;  
 unsigned int type:4; 
 unsigned int base_0_23:24; /* 基地址的低24位 */
 unsigned int seg_limit_0_15:16; /* 段长度的低16位 */
} 
```

所以每个描述符包含了32位的地址。

在Linux中，所有地址映射都使用GDT，最后2个位段标识权限，倒数第三个位段标识是否为GDT。

段描述符表分为三类：全局描述符表GDT，局部描述符表LDT和中断描述符表IDT

当 TI=0时表示段描述符在GDT中，如下图所示：
1. 先从GDTR寄存器中获得GDT基址。
2. 然后再GDT中以段选择符高13位位置索引值得到段描述符。
3. 段描述符符包含段的基址、限长、优先级等各种属性，这就得到了段的起始地址（基址），再以基址加上偏移地址yyyyyyyy才得到最后的线性地址。

![](2020-1-14-02-05-42.jpg)

当TI=1时表示段描述符在LDT中，如下图所示：
1. 还是先从GDTR寄存器中获得GDT基址。
2. 从LDTR寄存器中获取LDT所在段的位置索引(LDTR高13位)。
3. 以这个位置索引在GDT中得到LDT段描述符从而得到LDT段基址。
4. 用段选择符高13位位置索引值从LDT段中得到段描述符。
5. 段描述符符包含段的基址、限长、优先级等各种属性，这就得到了段的起始地址（基址），再以基址加上偏移地址yyyyyyyy才得到最后的线性地址。

![](2020-1-14-02-06-03.jpg)

所以，在通过GDT后，会得到逻辑地址，而由于Linux本身将基地址设置为0，所以虚拟地址和逻辑地址是一样的。

获取到逻辑地址后，MMU会通过CR3寄存器获取到PGD的信息，开始页表查询。

MMU最初以10,10,12作为位段，4K为一页，而每个表项是4字节，所以，1024个表项，正好就是4K。

![](2020-1-14-02-32-11.jpg)

4字节主要存储的是下一个页表的基地址，以及相关页表的描述信息。具体的映射关系如下：
1. 从CR3中取得页面目录的基地址
2. 以线性地址中的dir位段作为下标，获得对应的页表描述项
3. 以线性地址的page位段为下标，得到页面描述项
4. 将页面描述项的页面基地址与线性地址的偏移量相加得到物理地址

为何是使用20位作为基地址？由于2^12正好为4096个字节=4k大小，所以，正好是一个页描述符的基地址。

> 问题一：LDT和GDT的使用？

### 重要数据结构

#### 物理空间管理结构体

在Linux中，mem_map是一个page结构指针，存储了所有的页面结构体数组。同时针对所有页面都划分为了ZONE_DMA和ZONE_NORMAL2个管理区。这个后续再说。

针对每个管理区都有一个数据结构：zone_struct结构体。
首先，每个管理区都存在一组free_area_t队列，按页面大小加以管理，主要是4，8，16... 1024。最大为2的10次方的页面块，每个页面4K，也就是4M字节。

```
typedef struct zone_struct {
    spinlock_t lock;
    unsigned long offset;
    unsigned long free_pages;
    unsigned long inactive_clean_pages;
    unsigned long inactive_dirty_pages;
    unsigned long pages_min, pages_low, pages_high;

    struct list_head inactive_clean_list;
    free_area_t free_area[MAX_ORDER];

    char *name;
    unsigned long size;

    struct pglist_data *zone_pgdat;
    unsigned long zone_start_paddr;
    unsigned long zone_start_mapnr;
    struct page *zone_mem_map;
} zone_t;
```

`offset`表示分区在mem_map的起始页面号，而会存在连续一整块的页面都属于某个管理区。

```
typedef struct free_area_struct {
    struct list_head free_list;
    unsigned int *map;
} free_area_t;
```

为了支持NUMA，Linux在zone_struct结构体上增加了pglist_data结构体。

```
typedef struct pglist_data {
    zone_t node_zones[MAX_NR_ZONES];
    zonelist_t node_zonelists[NR_GFPINDEX];
    
    struct page *node_mem_map;
    unsigned long *valid_addr_bitmap;
    struct bootmem_data *bdata;
    
    unsigned long node_start_paddr;
    unsigned long node_start_mapnr;
    unsigned long node_size;

    int node_id;
    struct pglist_data *node_next;
} pg_data_t;
```

所有的pglist_data结构体，可通过node_next来形成一个单链队列。而每个结构体中的node_mem_map都指向具体节点的page结构数组。node_zones最多也有3个管理区，而每个zone结构体也存在一个zone_pgdat指针指向所属的pglist_data对象。

同时，在pglist_data中设置了node_zonelists数组。

```
typedef struct zonelist_struct {
    zone_t * zones [MAX_NR_ZONES+1]; // NULL delimited
    int gfp_mask;
} zonelist_t;
```

主要关联所有的zone，用于搜索不同的存储节点，表示了分配策略。每个存储节点都存在多个分配策略，大小为0x100（256种）所以要求分配页面时，需要说明采用哪种分配策略。

#### 虚拟空间管理结构体

Linux为每个进程分配了4GB的虚拟空间，其中，用户空间占了3GB。虽然当物理空间不连续的时候还是可以使用页表机制将其映射成连续的虚拟空间，但是实际上使用的时候虚拟空间也不一定是连续的。

所以在Linux内核中还有一个数据结构来管理成块的虚拟空间（include/linux/mm.h）

```
struct vm_area_struct {
    struct mm_struct * vm_mm;

    unsigned long vm_start;
    unsigned long vm_end;

    struct vm_area_struct *vm_next;
    pgprot_t vm_page_prot;
    unsigned long vm_flags;
    short vm_avl_height;

    struct vm_area_struct * vm_avl_left;
    struct vm_area_struct * vm_avl_right;

    struct vm_area_struct *vm_next_share;
    struct vm_area_struct **vm_pprev_share;

    struct vm_operations_struct * vm_ops;
    unsigned long vm_pgoff;
    struct file * vm_file;
    unsigned long vm_raend;
    void * vm_private_data;
};
```
每一个vm_area_struct管理一块连续的虚拟空间（注意：不同进程的虚拟用户空间一般不互相影响），vm_start和vm_end分别表示虚拟空间的开始和结束地址。

vm_next是用来连接统一进程的所有vm_area_struct序列链，是按照高低次序进行连接的。

当一个进程的虚存块划分地较少的时候可以使用链式连接查询，但是如果太多的话这样查询效率会降低，所以在块数较多的时候采用AVL树进行存储，也就是平衡二叉树。vm_area_struct中的vm_avl_height、vm_avl_left和vm_avl_right都是和AVL树有关。

vm_next_share、vm_pprev_share、vm_ops等都和磁盘文件以及内存换出等有关，在以后会说到。

在vm_area_struct开头有一个定义：struct mm_struct *vm_mm这个是表明它属于哪个内存进程的内存管理。

```
struct mm_struct {
    struct vm_area_struct * mmap;
    struct vm_area_struct * mmap_avl;
    struct vm_area_struct * mmap_cache;

    pgd_t * pgd;

    atomic_t mm_users;
    atomic_t mm_count;
    int map_count;
    struct semaphore mmap_sem;
    spinlock_t page_table_lock;

    struct list_head mmlist;
    
    unsigned long start_code, end_code, start_data, end_data;
    unsigned long start_brk, brk, start_stack;
    unsigned long arg_start, arg_end, env_start, env_end;
    unsigned long rss, total_vm, locked_vm;
    unsigned long def_flags;
    unsigned long cpu_vm_mask;
    unsigned long swap_cnt;
    unsigned long swap_address;
    
    mm_context_t context;
};
```

这个结构体是比vm_area_struct更高级的数据结构，每个进程都存在一个mm_struct结构体。在进程控制块task_struct结构体中都有一个指针指向mm_struct对象。

1. mmap用来建立一个虚存空间的单链队列；
2. mmap_avl用来建立虚存空间的AVL树；
3. mmap_cache用来指向最近一次用到的虚存区间结构；
4. pgd用来指向该进程的页目录表；
5. 一个进程的mm_struct可以为多个进程共享，mm_user和mm_count就是用来计数的；
6. map_count用来记录进程有几个虚存空间；
7. mmap_sem和page_table_lock是用来定义P、V操作的信号量。
8. 另外start_code、end_code等就是该进程的代码等起始、结束地址。

针对vm_area_struct的查询和插入都存在一个对应的流程。在查询虚存地址是否命中空间时，会先查询mmap_cache，(命中率高达35%)，若未命中则会通过avl进行定位，若不存在avl，则直接查询mmap链表。

而在插入的流程中，会先将vm_area_struct和mm_struct进行加锁，避免2者被修改。后会检查是否存在avl，若存在，则插入avl树中，同时再插入mmap链表中，最后赋值给mmap_cache。
avl的建立主要会针对vm个数大于32时触发。

### 越界访问

越界访问主要存在3种情况：
1. 访问的页面从未建立过，页表项为空
2. 访问的页面不在内存中
3. 访问的页面与权限不符，写入数据至只读页面

当存在上述的异常情况，cpu会触发do_page_fault函数处理相关页面。函数会传入2个参数：pt_regs表示异常场景下的各个寄存器数据、error_code表示异常的错误编号。

最初会有2个特殊case判断：是否为驱动程序、当前程序映射是否建立。若命中则不做继续的处理。

后续就利用find_vma方法来找到对应的虚存空间块。而在find_vma方法的处理上，主要会返回第一个地址小于目标地址的虚存空间。所以也就存在3种情况：*完全命中区间、完全未命中区间、在2个区间中的空洞*。

在命中2个区间中的空洞也存在2个情况：堆栈区、mmap的撤回区。

如果是命中了mmap的撤回区，那就是出现报错逻辑，那就应该对errcode变量进行判断处理并返回。

如果区域命中了VM_GROWSDOWN标记，那说明这个区域是堆栈区，那系统会尝试获取上方4个字节的地址是否还是比esp指针小，如果小，说明当前地址异常。否则就表示正常的增长的区域，所以需要进行扩展栈区。

进行栈区扩展的时候，会直接修改vm_struct结构体，后交由good_area流程处理。这里主要会检查当前命中的页面权限是否正常，如果写操作命中只读权限，那继续失败。

而当前扩展的新页面还是一个不存在物理内存的虚拟空间，则继续调用handle_mm_fault方法分配页面。该方法会检查pte，若不存在则分配页面。而针对pte对应的页面有缺失时，会调用do_no_page方法来分配，底层继续调用do_anonymous_page方法来分配实际的物理页面。最后将页面和pte进行绑定处理。


### 物理页面的使用和流转

首先，在系统初始化阶段，内核根据检测到的物理内存大小，未每一个页面都建立一个page结构，形成一个page结构的数组，并使一个全局量mem_map指向这个数组。后续又建立zone管理区来管理页面。

与此类似，针对物理设备，也存在一个类似的管理结构体：swap_info_struct，用于描述和管理页面交换的文件和设备。

```
struct swap_info_struct {
    unsigned int flags;
    kdev_t swap_device;
    spinlock_t sdev_lock;
    struct dentry * swap_file;
    struct vfsmount *swap_vfsmnt;
    unsigned short * swap_map;
    unsigned int lowest_bit;
    unsigned int highest_bit;
    unsigned int cluster_next;
    unsigned int cluster_nr;
    int prio; /* swap priority */
    int pages;
    unsigned long max;
    int next; /* next entry on swap list */
};
```
1. swap_map指向一个数组代表一个物理页面，而第一个页面主要用于描述整个设备的信息。
2. pages表示数组的大小。
3. lowest_bit和highest_bit表示一个可使用的物理页面区间
4. max这是最大的页面号
5. cluster_next和cluster_nr也主要用于适用多个磁盘按集群做区分

Linux内核本身允许多个页面交互设备，所以在内核中建立了一个swap_info的数组。同时又支持根据优先级进行排序，故支持了swap_list列表。当swap_on指定文件用于页面交换时候，就会插入列表中。

针对已被换出的页面，pte中也存在特定的结构swp_entry来对应，这结构也是一个32位的长整型：24位offset、7位的type、1位的标记。
offset标识属于哪个磁盘设备，type标识磁盘的哪个文件（也就是最大127个）。所以，针对pte最后一位为0的情况，说明已经换出页面。MMU此时也不对该页做处理，由Linux内核来确定对应的位置。
在释放页面的操作中，Linux内核会针对页面传入要释放的次数，当不在引用后，当前页面也就被真正释放，并插入lowest和highest中。

所谓的内存页面周转主要存在2种情况：
1. 页面的分配、使用和回收，意义就在于在内存中对页面的状态进行标记和管理
2. 盘区交换，主要也就是页面的回收

而并非所有的内存页面都可以交换出去，只有映射到用户空间的页面才会交换出去。（所谓的用户空间，指至少一个进程的用户空间的映射页面。
所有的用户空间可分为以下几类：
1. 普通的用户空间页面，例如进程的代码段、数据段、堆栈段
2. 通过系统调用mmap映射到用户空间
3. 进程间的共享内存区

而针对系统空间的内存区域，由于不会置换出去，周转流程也就是 空闲->分配->使用->释放->空闲。而针对用途，系统空间由分为两类：
1. 内核通过kmalloc或vmalloc分配的临时对象
2. 内存通过alloc_page分配，用做临时性使用和为管理目的的内存页面

而内核为了可以复用，还存在一类页面，虽然使用完，但不会直接回收，主要也分为三类：
1. 在文件系统操作中用来缓存文件目录结构dentry结构的空间
2. 在文件系统操作中用来缓存存储一些inode结构的空间
3. 用于文件系统读写操作的缓存区

针对页面交换，存在一系列复杂的策略。
首先最简单的一个策略：每缺页异常时，便分配一个内存页面，并把磁盘的页面读入已分配的内存中。如果没有空闲页面就尝试换出到磁盘中。缺点在于：临阵磨枪，如果忙碌的时候，就很占用时间。
于是做一次优化，定期的，预先维护一部分的内存页面，保证中断时由页面可供分配。但是，算法不能完全预测页面的访问，容易出现一个页面抖动的性能异常。
为了更加节约性能，页面可以支持一个暂存队列，当被换出时，保留当前的数据，当发生中断的时候，去暂存区域获取一个可用的内存页面。若未被回收，那当前页面建立映射的耗时就很简单。
这里面存在一个不断的页面写入磁盘的频繁操作，为此，进一步优化对于一个页面，操作系统如果被换成的时候，保证页面和磁盘相同，表明是一个干净的内容，如果页面是干净的，那就不用频繁写入磁盘空间。


为了支持算法，系统提供了2个全局链表：active_list和inactive_dirty_list，表示全局的活跃page和不活跃脏的page，而在页面管理区都有一个inactive_clean_list链表，这由于所有的page都由zone进行管理。
同时系统还通过address_space和swapper_space2个结构体管理可交换的内存页面。（为了加快搜索，设置了page_hash_table哈希表。




## 地址映射过程

## 重要数据结构、函数

## 越界访问

## 用户堆栈管理

## 物理内存的使用和周转

## 页面的周转

## 内存缓冲区的管理

## 外部设备的地址映射

## 系统调用-brk和mmap


## 相关链接
1. [PAE 分页模式详解](https://www.cnblogs.com/ck1020/p/6078214.html)