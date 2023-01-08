---
title: Redis新协议-RESP3
abbrlink: 9738
date: 2023-01-08 23:44:38
tags:
---

在新的Redis中，由于存在一些Lua、Function、Module等插件类功能，其中需要依赖基础的call方法来调用原生方法，此时就需要对实际命令调用后结果进行解析。这也引入了对协议解析的抽象层。

## 关于协议

新的Resp3协议引入了很多概念，包括了Map、BigNumber、Set等，为了更好的了解协议情况，直接贴出解析入口方法：

```
/* Parse a reply pointed to by parser->curr_location. */
int parseReply(ReplyParser *parser, void *p_ctx) {
    switch (parser->curr_location[0]) {
        case '$': return parseBulk(parser, p_ctx);
        case '+': return parseSimpleString(parser, p_ctx);
        case '-': return parseError(parser, p_ctx);
        case ':': return parseLong(parser, p_ctx);
        case '*': return parseArray(parser, p_ctx);
        case '~': return parseSet(parser, p_ctx);
        case '%': return parseMap(parser, p_ctx);
        case '#': return parseBool(parser, p_ctx);
        case ',': return parseDouble(parser, p_ctx);
        case '_': return parseNull(parser, p_ctx);
        case '(': return parseBigNumber(parser, p_ctx);
        case '=': return parseVerbatimString(parser, p_ctx);
        case '|': return parseAttributes(parser, p_ctx);
        default: if (parser->callbacks.error) parser->callbacks.error(p_ctx);
    }
    return C_ERR;
}

```

由此可见，此处有13个协议标记，单独予以归类：
- 简单类型：`+`、`-`、`:`、`#`、`,`、`(`、`=`、`_`
- 复杂类型：`$`、`*`、`~`、`%`、`|`

为了统一进行解析，此处对协议解析进行了抽象：

```
static const ReplyParserCallbacks DefaultParserCallbacks = {
    .null_callback = callReplyNull,
    .bulk_string_callback = callReplyBulkString,
    .null_bulk_string_callback = callReplyNullBulkString,
    .null_array_callback = callReplyNullArray,
    .error_callback = callReplyError,
    .simple_str_callback = callReplySimpleStr,
    .long_callback = callReplyLong,
    .array_callback = callReplyArray,
    .set_callback = callReplySet,
    .map_callback = callReplyMap,
    .double_callback = callReplyDouble,
    .bool_callback = callReplyBool,
    .big_number_callback = callReplyBigNumber,
    .verbatim_string_callback = callReplyVerbatimString,
    .attribute_callback = callReplyAttribute,
    .error = callReplyParseError,
};
```

实际的场景主要在于Module需要解析协议进行处理，以及Lua需要将协议转换为lua数据并执行。
从最初的代码中，可以看到解析主要依赖俩块数据：`parser`、`ctx`，前者代码解析时回调，而后者主要是解析时传入的上下文信息。

## 协议内容

此处，针对不同类型的默认解析器进行讲解，方便后续理解

### parseNull 解析

协议为 `_` 数据，解析直接赋值相关类型以及长度，占用空间为3字节。

```
static int parseNull(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    parser->curr_location = p + 2; /* for \r\n */
    parser->callbacks.null_callback(p_ctx, proto, parser->curr_location - proto);
    return C_OK;
}

static void callReplyNull(void *ctx, const char *proto, size_t proto_len) {
    CallReply *rep = ctx;
    callReplySetSharedData(rep, REDISMODULE_REPLY_NULL, proto, proto_len, REPLY_FLAG_RESP3);
}
```

### parseBulk 解析

协议为 `$` 开头的数据，并解析出 2字节的长度信息以及实际的内容，如果长度为-1，则认为是空数据。与Null相同意思。

```
static int parseBulk(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    long long bulklen;
    parser->curr_location = p + 2; /* for \r\n */

    string2ll(proto+1,p-proto-1,&bulklen);
    if (bulklen == -1) {
        parser->callbacks.null_bulk_string_callback(p_ctx, proto, parser->curr_location - proto);
    } else {
        const char *str = parser->curr_location;
        parser->curr_location += bulklen;
        parser->curr_location += 2; /* for \r\n */
        parser->callbacks.bulk_string_callback(p_ctx, str, bulklen, proto, parser->curr_location - proto);
    }

    return C_OK;
}
```

### parseError 解析

协议为 `-` 开头的数据，并解析出实际的内容，并直接设置具体内容。

```
static int parseError(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    parser->curr_location = p + 2; // for \r\n
    parser->callbacks.error_callback(p_ctx, proto+1, p-proto-1, proto, parser->curr_location - proto);
    return C_OK;
}
```

### parseSimpleString 解析

协议为 `-` 开头的数据，并解析出实际的内容，并直接设置具体内容。与Error一样的操作。

```
static int parseSimpleString(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    parser->curr_location = p + 2; /* for \r\n */
    parser->callbacks.simple_str_callback(p_ctx, proto+1, p-proto-1, proto, parser->curr_location - proto);
    return C_OK;
}
```

### parseLong 解析

协议为 `:` 开头的数据，并解析出 2字节的数据信息。

```
static int parseLong(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    parser->curr_location = p + 2; /* for \r\n */
    long long val;
    string2ll(proto+1,p-proto-1,&val);
    parser->callbacks.long_callback(p_ctx, val, proto, parser->curr_location - proto);
    return C_OK;
}

static void callReplyLong(void *ctx, long long val, const char *proto, size_t proto_len) {
    CallReply *rep = ctx;
    callReplySetSharedData(rep, REDISMODULE_REPLY_INTEGER, proto, proto_len, 0);
    rep->val.ll = val;
}

```

### parseArray 解析

协议为 `$` 开头的数据，并解析出 2字节的元素个数信息，并最终调用`callReplyParseCollection` 进行递归解析协议内容。后续会单独讲解解析后的数据如何存放。

```
static int parseArray(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    long long len;
    string2ll(proto+1,p-proto-1,&len);
    p += 2;
    parser->curr_location = p;
    if (len == -1) {
        parser->callbacks.null_array_callback(p_ctx, proto, parser->curr_location - proto);
    } else {
        parser->callbacks.array_callback(parser, p_ctx, len, proto);
    }
    return C_OK;
}

static void callReplyArray(ReplyParser *parser, void *ctx, size_t len, const char *proto) {
    CallReply *rep = ctx;
    rep->type = REDISMODULE_REPLY_ARRAY;
    callReplyParseCollection(parser, rep, len, proto, 1);
}
```

### parseSet 解析

协议为 `~` 开头的数据，并解析出 2字节的元素个数信息，并最终调用`callReplyParseCollection` 进行递归解析协议内容。由此可见，Set和Array内容基本上相似。

```
static int parseSet(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    long long len;
    string2ll(proto+1,p-proto-1,&len);
    p += 2;
    parser->curr_location = p;
    parser->callbacks.set_callback(parser, p_ctx, len, proto);
    return C_OK;
}

static void callReplySet(ReplyParser *parser, void *ctx, size_t len, const char *proto) {
    CallReply *rep = ctx;
    rep->type = REDISMODULE_REPLY_SET;
    callReplyParseCollection(parser, rep, len, proto, 1);
    rep->flags |= REPLY_FLAG_RESP3;
}
```

### parseMap 解析

协议为 `%` 开头的数据，并解析出 2字节的元素个数信息，并最终调用`callReplyParseCollection` 进行递归解析协议内容。由此可见，Set、Array、Map内容基本上相似。

```
static int parseMap(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    long long len;
    string2ll(proto+1,p-proto-1,&len);
    p += 2;
    parser->curr_location = p;
    parser->callbacks.map_callback(parser, p_ctx, len, proto);
    return C_OK;
}

static void callReplyMap(ReplyParser *parser, void *ctx, size_t len, const char *proto) {
    CallReply *rep = ctx;
    rep->type = REDISMODULE_REPLY_MAP;
    callReplyParseCollection(parser, rep, len, proto, 2);
    rep->flags |= REPLY_FLAG_RESP3;
}

```


### parseDouble 解析

协议为 `,` 开头的数据，并解析出全量数据，并以此复制到buffer中，并进行转换，其中最大的空间为：`5*1024`。

```
static int parseDouble(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    parser->curr_location = p + 2; /* for \r\n */
    char buf[MAX_LONG_DOUBLE_CHARS+1];
    size_t len = p-proto-1;
    double d;
    if (len <= MAX_LONG_DOUBLE_CHARS) {
        memcpy(buf,proto+1,len);
        buf[len] = '\0';
        d = strtod(buf,NULL); /* We expect a valid representation. */
    } else {
        d = 0;
    }
    parser->callbacks.double_callback(p_ctx, d, proto, parser->curr_location - proto);
    return C_OK;
}

```


### parseBool 解析

协议为 `#` 开头的数据，并解析一个字节：`t` 或者 `f`，来区分bool的数值。

```
static int parseBool(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    parser->curr_location = p + 2; /* for \r\n */
    parser->callbacks.bool_callback(p_ctx, proto[1] == 't', proto, parser->curr_location - proto);
    return C_OK;
}

static void callReplyBool(void *ctx, int val, const char *proto, size_t proto_len) {
    CallReply *rep = ctx;
    callReplySetSharedData(rep, REDISMODULE_REPLY_BOOL, proto, proto_len, REPLY_FLAG_RESP3);
    rep->val.ll = val;
}
```

### parseBigNumber 解析

协议为 `(` 开头的数据，并解析出全量数据，并以此复制到buffer中，最终的表现形式还是为字符串。

```
static int parseBigNumber(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    parser->curr_location = p + 2; /* for \r\n */
    parser->callbacks.big_number_callback(p_ctx, proto+1, p-proto-1, proto, parser->curr_location - proto);
    return C_OK;
}

static void callReplyBigNumber(void *ctx, const char *str, size_t len, const char *proto, size_t proto_len) {
    CallReply *rep = ctx;
    callReplySetSharedData(rep, REDISMODULE_REPLY_BIG_NUMBER, proto, proto_len, REPLY_FLAG_RESP3);
    rep->len = len;
    rep->val.str = str;
}
```

### parseAttributes 解析

协议为 `|` 开头的数据，并解析出 2字节的元素个数信息，并最终调用`callReplyParseCollection` 进行递归解析协议内容，解析后，会再次调用 `parseReply` 单独解析内容。

```
static int parseAttributes(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    long long len;
    string2ll(proto+1,p-proto-1,&len);
    p += 2;
    parser->curr_location = p;
    parser->callbacks.attribute_callback(parser, p_ctx, len, proto);
    return C_OK;
}

static void callReplyAttribute(ReplyParser *parser, void *ctx, size_t len, const char *proto) {
    CallReply *rep = ctx;
    rep->attribute = zcalloc(sizeof(CallReply));

    /* Continue parsing the attribute reply */
    rep->attribute->len = len;
    rep->attribute->type = REDISMODULE_REPLY_ATTRIBUTE;
    callReplyParseCollection(parser, rep->attribute, len, proto, 2);
    rep->attribute->flags |= REPLY_FLAG_PARSED | REPLY_FLAG_RESP3;
    rep->attribute->private_data = rep->private_data;

    /* Continue parsing the reply */
    parseReply(parser, rep);

    /* In this case we need to fix the proto address and len, it should start from the attribute */
    rep->proto = proto;
    rep->proto_len = parser->curr_location - proto;
    rep->flags |= REPLY_FLAG_RESP3;
}

```

### parseVerbatimString 解析

协议为 `=` 开头的数据，并解析出2字节的长度后，由会取出4个字节作为format信息，最终剩余的空间为二进制安全字符串。

```
static int parseVerbatimString(ReplyParser *parser, void *p_ctx) {
    const char *proto = parser->curr_location;
    char *p = strchr(proto+1,'\r');
    long long bulklen;
    parser->curr_location = p + 2; /* for \r\n */
    string2ll(proto+1,p-proto-1,&bulklen);
    const char *format = parser->curr_location;
    parser->curr_location += bulklen;
    parser->curr_location += 2; /* for \r\n */
    parser->callbacks.verbatim_string_callback(p_ctx, format, format + 4, bulklen - 4, proto, parser->curr_location - proto);
    return C_OK;
}

static void callReplyVerbatimString(void *ctx, const char *format, const char *str, size_t len, const char *proto, size_t proto_len) {
    CallReply *rep = ctx;
    callReplySetSharedData(rep, REDISMODULE_REPLY_VERBATIM_STRING, proto, proto_len, REPLY_FLAG_RESP3);
    rep->len = len;
    rep->val.verbatim_str.str = str;
    rep->val.verbatim_str.format = format;
}
```



## 特殊源码

### 协议结构

单独来了解一下默认协议的表示结构体：

```
struct CallReply {
    void *private_data;
    sds original_proto; /* Available only for root reply. */
    const char *proto;
    size_t proto_len;
    int type;       /* REPLY_... */
    int flags;      /* REPLY_FLAG... */
    size_t len;     /* Length of a string, or the number elements in an array. */
    union {
        const char *str; /* String pointer for string and error replies. This
                          * does not need to be freed, always points inside
                          * a reply->proto buffer of the reply object or, in
                          * case of array elements, of parent reply objects. */
        struct {
            const char *str;
            const char *format;
        } verbatim_str;  /* Reply value for verbatim string */
        long long ll;    /* Reply value for integer reply. */
        double d;        /* Reply value for double reply. */
        struct CallReply *array; /* Array of sub-reply elements. used for set, array, map, and attribute */
    } val;
    list *deferred_error_list;   /* list of errors in sds form or NULL */
    struct CallReply *attribute; /* attribute reply, NULL if not exists */
};
```

大体可以分为三块内容：
1. 协议信息
2. 数据部分
3. 析构处理

#### 协议信息

```
    void *private_data;
    sds original_proto; /* Available only for root reply. */
    const char *proto;
    size_t proto_len;
    int type;       /* REPLY_... */
    int flags;      /* REPLY_FLAG... */
    size_t len;     /* Length of a string, or the number elements in an array. */
```

从上到下分别为：特殊透传数据、reply根地址、reply当前解析地址、reply长度、当前协议类型、当前的标记位。

#### 数据部分

```
    size_t len;     /* Length of a string, or the number elements in an array. */
    union {
        const char *str; /* String pointer for string and error replies. This
                          * does not need to be freed, always points inside
                          * a reply->proto buffer of the reply object or, in
                          * case of array elements, of parent reply objects. */
        struct {
            const char *str;
            const char *format;
        } verbatim_str;  /* Reply value for verbatim string */
        long long ll;    /* Reply value for integer reply. */
        double d;        /* Reply value for double reply. */
        struct CallReply *array; /* Array of sub-reply elements. used for set, array, map, and attribute */
    } val;
	   struct CallReply *attribute; /* attribute reply, NULL if not exists */
```

整体通过一个union属性来包裹了value信息，其中有string、verbatim_str、number、double、array类型，同时这部分还有一个len代表元素的长度信息。

其中，我们将 `attribute` 也做为数据部分看待，因为，它也可以表示实际的信息。

### 析构处理

```
    list *deferred_error_list;   /* list of errors in sds form or NULL */
```

这块的逻辑主要是在于完成解析后，数据的释放流程：

```
void freeCallReply(CallReply *rep) {
    if (!(rep->flags & REPLY_FLAG_ROOT)) {
        return;
    }
    if (rep->flags & REPLY_FLAG_PARSED) {
        freeCallReplyInternal(rep);
    }
    sdsfree(rep->original_proto);
    if (rep->deferred_error_list)
        listRelease(rep->deferred_error_list);
    zfree(rep);
}
```

### 递归逻辑

本节单独解析 `callReplyParseCollection` 方法，源码如下：

```
static void callReplyParseCollection(ReplyParser *parser, CallReply *rep, size_t len, const char *proto, size_t elements_per_entry) {
    rep->len = len;
    rep->val.array = zcalloc(elements_per_entry * len * sizeof(CallReply));
    for (size_t i = 0; i < len * elements_per_entry; i += elements_per_entry) {
        for (size_t j = 0 ; j < elements_per_entry ; ++j) {
            rep->val.array[i + j].private_data = rep->private_data;
            parseReply(parser, rep->val.array + i + j);
            rep->val.array[i + j].flags |= REPLY_FLAG_PARSED;
            if (rep->val.array[i + j].flags & REPLY_FLAG_RESP3) {
                /* If one of the sub-replies is RESP3, then the current reply is also RESP3. */
                rep->flags |= REPLY_FLAG_RESP3;
            }
        }
    }
    rep->proto = proto;
    rep->proto_len = parser->curr_location - proto;
}
```

其中有趣的点在于，为了支持Map和Array的操作，增加了len和elements_per_entry变量。前者表示元素个数，后者则代表，每个元素中，存在多少个数据。例如Map每个元素存在key和value俩类数据，而Array只存在Value。这么设计最终完成了Map和Array的统一，以及更好的支持了Map本身递归表示的能力。