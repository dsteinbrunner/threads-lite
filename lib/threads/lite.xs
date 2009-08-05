#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/*
 * Some definitions that were copied verbatim froms threads.xs, these need to be looked at
 */

#ifdef WIN32
#  undef setjmp
#  if !defined(__BORLANDC__)
#    define setjmp(x) _setjmp(x)
#  endif
#endif
//XXX

#ifdef WIN32
#  include <windows.h>
   /* Supposed to be in Winbase.h */
#  ifndef STACK_SIZE_PARAM_IS_A_RESERVATION
#    define STACK_SIZE_PARAM_IS_A_RESERVATION 0x00010000
#  endif
#  include <win32thread.h>
#else
#  ifdef OS2
typedef perl_os_thread pthread_t;
#  else
#    include <pthread.h>
#  endif
#  include <thread.h>
#  define PERL_THREAD_SETSPECIFIC(k,v) pthread_setspecific(k,v)
#  ifdef OLD_PTHREADS_API
#    define PERL_THREAD_DETACH(t) pthread_detach(&(t))
#  else
#    define PERL_THREAD_DETACH(t) pthread_detach((t))
#  endif
#endif
#if !defined(HAS_GETPAGESIZE) && defined(I_SYS_PARAM)
#  include <sys/param.h>
#endif

#ifndef WIN32
STATIC int S_set_sigmask(sigset_t *);
#endif

/*
 * struct message
 */

enum node_type { STRING = 1, STORABLE = 2, QUEUE = 3, THREAD = 4 };

typedef struct message_queue message_queue;
typedef struct mthread mthread;

typedef struct {
	enum node_type type;
	union {
		struct {
			char* ptr;
			STRLEN length;
		} string;
		message_queue* queue;
		mthread* thread;
	};
} message;

SV* S_message_get_sv(pTHX_ message* message) {
	SV* stored = newSV_type(SVt_PV);
	SvPVX(stored) = message->string.ptr;
	SvLEN(stored) = SvCUR(stored) = message->string.length;
	SvPOK_only(stored);
	return stored;
}

#define message_get_sv(message) S_message_get_sv(aTHX_ message)

void S_message_set_sv(pTHX_ message* message, SV* value, enum node_type type) {
	message->type = type;
	char* string = SvPV(value, message->string.length);
	message->string.ptr = savepvn(string, message->string.length);
}

#define message_set_sv(message, value, type) S_message_set_sv(aTHX_ message, value, type)

void S_message_store_value(pTHX_ message* message, SV* value) {
	dSP;
	ENTER;
	SAVETMPS;
	sv_setiv(save_scalar(gv_fetchpv("Storable::Deparse", TRUE | GV_ADDMULTI, SVt_PV)), 1);
	PUSHMARK(SP);
	PUSHs(sv_2mortal(newRV_inc(value)));
	PUTBACK;
	call_pv("Storable::mstore", G_SCALAR);
	SPAGAIN;
	message_set_sv(message, POPs, STORABLE);
	FREETMPS;
	LEAVE;
}

#define message_store_value(message, value) S_message_store_value(aTHX_ message, value)

void queue_delref(message_queue*);

void S_message_destroy(pTHX_ message* message) {
	switch(message->type) {
		case STRING:
		case STORABLE:
			Safefree(message->string.ptr);
			break;
		case QUEUE:
			queue_delref(message->queue);
			break;
		case THREAD:
			//XXX
			break;
		default:
			Perl_warn(aTHX_ "Unknown type in queue\n");
	}
	Zero(message, 1, message);
}

/*
 * Message queues
 */

typedef struct queue_node {
	message message;
	struct queue_node* next;
} queue_node;

void node_unshift(queue_node** position, queue_node* new_node) {
	new_node->next = *position;
	*position = new_node;
}

queue_node* node_shift(queue_node** position) {
	queue_node* ret = *position;
	*position = (*position)->next;
	return ret;
}

void node_push(queue_node** end, queue_node* new_node) {
	queue_node** cur = end;
	while(*cur)
		cur = &(*cur)->next;
	*end = *cur = new_node;
	new_node->next = NULL;
}

struct message_queue {
	perl_mutex mutex;
	perl_cond condvar;
	queue_node* front;
	queue_node* back;
	queue_node* reserve;
	UV refcnt;
};

message_queue* queue_new() {
	message_queue* queue;
	Newxz(queue, 1, message_queue);
	MUTEX_INIT(&queue->mutex);
	COND_INIT(&queue->condvar);
	queue->refcnt = 1;
	return queue;
}

void* S_get_pointer_from(pTHX_ SV* queue_obj) {
	MAGIC* magic;
	if (!SvROK(queue_obj) || !SvMAGICAL(SvRV(queue_obj)) || !(magic = mg_find(SvRV(queue_obj), PERL_MAGIC_ext)))
		Perl_croak(aTHX_ "Something is very wrong, this is not a magic object\n");
	return (void*)magic->mg_ptr;
}

#define get_pointer_from(obj) S_get_pointer_from(aTHX_ obj)
#define get_queue_from(obj) (message_queue*)get_pointer_from(obj)
#define get_thread_from(obj) (mthread*)get_pointer_from(obj)

void queue_addref(message_queue* queue) {
	MUTEX_LOCK(&queue->mutex);
	assert(queue->refcnt);
	++queue->refcnt;
	MUTEX_UNLOCK(&queue->mutex);
}

void queue_delref(message_queue* queue) {
	MUTEX_LOCK(&queue->mutex);
	--queue->refcnt;
	if (queue->refcnt == 0) {
		queue_node *current, *next;
		for (current = queue->front; current; current = next) {
			next = current->next;
			message_destroy(current->message);
			Safefree(current);
		}
		for (current = queue->reserve; current; current = next) {
			next = current->next;
			Safefree(current);
		}
		COND_FREE(&queue->condvar);
		MUTEX_UNLOCK(&queue->mutex);
		MUTEX_FREE(&queue->mutex);
	}
	else
		MUTEX_UNLOCK(&queue->mutex);
}

void S_queue_enqueue(pTHX_ message_queue* queue, SV** argslist, UV length) {
	message message;

	if (length == 1) {
		SV* arg = *argslist;
		if (SvROK(arg) && sv_isobject(arg) && sv_isa(arg, "threads::lite")) {
			message.type = THREAD;
			message.thread = get_thread_from(arg);
//			thread_addref(message.thread);
		}
		else if (SvROK(arg) && sv_isobject(arg) && sv_isa(arg, "threads::lite::queue")) {
			message.type = QUEUE;
			message.queue = get_queue_from(arg);
			queue_addref(message.queue);
		}
		else if (!SvOK(arg) || SvROK(arg) || (SvPOK(arg) && SvUTF8(arg)))
			message_store_value(&message, arg);
		else
			message_set_sv(&message, arg, STRING);
	}
	else {
		SV* list = sv_2mortal((SV*)av_make(length, argslist));
		message_store_value(&message, list);
	}

	MUTEX_LOCK(&queue->mutex);

	queue_node* new_entry;
	if (queue->reserve) {
		new_entry = node_shift(&queue->reserve);
	}
	else
		Newx(new_entry, 1, queue_node);

	Copy(&message, &new_entry->message, 1, message);
	new_entry->next = NULL;

	node_push(&queue->back, new_entry);
	if (queue->front == NULL)
		queue->front = queue->back;

	COND_SIGNAL(&queue->condvar);
	MUTEX_UNLOCK(&queue->mutex);
}

#define queue_enqueue(queue, args, length) S_queue_enqueue(aTHX_ queue, args, length)

static MGVTBL table = { 0 };

SV* S_object_new(pTHX_ HV* stash) {
	SV* ret = newRV_noinc(newSV_type(SVt_PVMG));
	sv_bless(ret, stash);
}

#define object_new(hash) S_object_new(aTHX_ hash)

SV* S_queue_object_new(pTHX_ message_queue* queue, HV* stash, bool addref) {
	if (stash == NULL)
		stash = gv_stashpv("threads::lite::queue", FALSE);
	SV* ret = object_new(stash);
	sv_magicext(SvRV(ret), NULL, PERL_MAGIC_ext, &table, (char*)queue, 0);
	if (addref)
		queue_addref(queue);
	return ret;
}

#define queue_object_new(queue, stash, addref) S_queue_object_new(aTHX_ queue, stash, addref)

SV* S_deserialize(pTHX_ message* message) {
	switch(message->type) {
		case STRING:
			return sv_2mortal(message_get_sv(message));
		case STORABLE: {
			dSP;
			ENTER;
			sv_setiv(save_scalar(gv_fetchpv("Storable::Eval", TRUE | GV_ADDMULTI, SVt_PV)), 1);
			PUSHMARK(SP);
			XPUSHs(sv_2mortal(message_get_sv(message)));
			PUTBACK;
			call_pv("Storable::thaw", G_SCALAR);
			SPAGAIN;
			LEAVE;
			return SvRV(POPs);
		}
		case QUEUE:
			return queue_object_new(message->queue, NULL, TRUE);
		case THREAD: {
			SV* ret = object_new(gv_stashpv("threads::lite", FALSE));
			sv_magicext(SvRV(ret), NULL, PERL_MAGIC_ext, &table, (char*)message->thread, 0);
			return ret;
		}
		default:
			Perl_croak(aTHX_ "Type %d is not yet implemented", message->type);
	}
}

#define deserialize(stored) S_deserialize(aTHX_ stored)

SV* S_queue_dequeue(pTHX_ message_queue* queue) {
	message message;
	MUTEX_LOCK(&queue->mutex);

	while (!queue->front)
		COND_WAIT(&queue->condvar, &queue->mutex);

	queue_node* front = node_shift(&queue->front);
	Copy(&front->message, &message, 1, message);
	node_unshift(&queue->reserve, front);

	if (queue->front == NULL)
		queue->back = NULL;

	MUTEX_UNLOCK(&queue->mutex);
	return deserialize(&message);
}

#define queue_dequeue(queue) S_queue_dequeue(aTHX_ queue)

SV* S_queue_dequeue_nb(pTHX_ message_queue* queue) {
	message message;

	MUTEX_LOCK(&queue->mutex);

	if(queue->front) {
		queue_node* front = node_shift(&queue->front);
		Copy(&front->message, &message, 1, message);
		node_unshift(&queue->reserve, front);

		if (queue->front == NULL)
			queue->back = NULL;

		MUTEX_UNLOCK(&queue->mutex);
		return deserialize(&message);
	}
	else {
		MUTEX_UNLOCK(&queue->mutex);
		return NULL;
	}
}

#define queue_dequeue_nb(queue) S_queue_dequeue_nb(aTHX_ queue)

void S_push_queued(pTHX_ SV* values) {
	dSP;
	
	if (SvTYPE(values) == SVt_PVAV) {
		if (GIMME_V == G_SCALAR) {
			SV** ret = av_fetch((AV*)values, 0, FALSE);
			PUSHs(ret ? *ret : &PL_sv_undef);
		}
		else if (GIMME_V == G_ARRAY) {
			UV count = av_len((AV*)values) + 1;
			Copy(AvARRAY((AV*)values), SP + 1, count, SV*);
			SP += count;
		}
	}
	else {
		PUSHs(values);
	}
	PUTBACK;
}

#define push_queued(values) STMT_START { PUTBACK; S_push_queued(aTHX_ values); SPAGAIN; } STMT_END

/*
 * Threads implementation itself
 */

static struct {
	perl_mutex lock;
	bool inited;
	UV count;
} global;

struct mthread {
	PerlInterpreter *interp;    /* The threads interpreter */
	message_queue* queue;

#ifdef WIN32
	DWORD  thr;                 /* OS's idea if thread id */
	HANDLE handle;              /* OS's waitable handle */
#else
	pthread_t thr;              /* OS's handle for the thread */
	sigset_t initial_sigmask;   /* Thread wakes up with signals blocked */
#endif
	IV stack_size;
	UV refcnt;
};

void boot_DynaLoader(pTHX_ CV* cv);

static void xs_init(pTHX) {
	dXSUB_SYS;
	newXS((char*)"DynaLoader::boot_DynaLoader", boot_DynaLoader, (char*)__FILE__);
}

static const char* argv[] = {"", "-e", "threads::lite::_run()"};
static int argc = sizeof argv / sizeof *argv;

void* run_thread(void* arg) {
	MUTEX_LOCK(&global.lock);
	++global.count;
	MUTEX_UNLOCK(&global.lock);

	mthread* thread = (mthread*) arg;
	PerlInterpreter* my_perl = perl_alloc();
	thread->interp = my_perl;
	perl_construct(my_perl);
	PL_exit_flags |= PERL_EXIT_DESTRUCT_END;

	perl_parse(my_perl, xs_init, argc, (char**)argv, NULL);
	load_module(PERL_LOADMOD_DENY, newSVpv("threads::lite", 0), NULL, NULL);
	S_set_sigmask(&thread->initial_sigmask);

	dSP;
	SAVETMPS;
	PUSHMARK(SP);
	PUSHs(sv_2mortal(queue_object_new(thread->queue, NULL, TRUE)));
	PUTBACK;
	call_pv("threads::lite::_run", G_VOID);
	SPAGAIN;
	FREETMPS;

	MUTEX_LOCK(&global.lock);
	--global.count;
	MUTEX_UNLOCK(&global.lock);
	return NULL;
}

static int S_mthread_hook(pTHX) {
	MUTEX_LOCK(&global.lock);
	int ret = global.count;
	MUTEX_UNLOCK(&global.lock);
	return ret;
}

#ifndef WIN32
/* Block most signals for calling thread, setting the old signal mask to
 * oldmask, if it is not NULL */
STATIC int
S_block_most_signals(sigset_t *oldmask)
{
	sigset_t newmask;

	sigfillset(&newmask);
	/* Don't block certain "important" signals (stolen from mg.c) */
#ifdef SIGILL
	sigdelset(&newmask, SIGILL);
#endif
#ifdef SIGBUS
	sigdelset(&newmask, SIGBUS);
#endif
#ifdef SIGSEGV
	sigdelset(&newmask, SIGSEGV);
#endif

#if defined(VMS)
	/* no per-thread blocking available */
	return sigprocmask(SIG_BLOCK, &newmask, oldmask);
#else
	return pthread_sigmask(SIG_BLOCK, &newmask, oldmask);
#endif /* VMS */
}

/* Set the signal mask for this thread to newmask */
STATIC int
S_set_sigmask(sigset_t *newmask)
{
#if defined(VMS)
	return sigprocmask(SIG_SETMASK, newmask, NULL);
#else
	return pthread_sigmask(SIG_SETMASK, newmask, NULL);
#endif /* VMS */
}
#endif /* WIN32 */

mthread* create_thread(IV stack_size) {
	mthread* thread;
	Newxz(thread, 1, mthread);
	thread->queue = queue_new();
	thread->stack_size = stack_size;
#ifdef WIN32
	thread->handle = CreateThread(NULL,
								  (DWORD)thread->stack_size,
								  run_thread,
								  (LPVOID)thread,
								  STACK_SIZE_PARAM_IS_A_RESERVATION,
								  &thread->thr);
#else
    int rc_stack_size = 0;
    int rc_thread_create = 0;

	S_block_most_signals(&thread->initial_sigmask);

	STATIC pthread_attr_t attr;
	STATIC int attr_inited = 0;
	STATIC int attr_joinable = PTHREAD_CREATE_JOINABLE;
	if (! attr_inited) {
		pthread_attr_init(&attr);
		attr_inited = 1;
	}

#  ifdef PTHREAD_ATTR_SETDETACHSTATE
	/* Threads start out joinable */
	PTHREAD_ATTR_SETDETACHSTATE(&attr, attr_joinable);
#  endif

#  ifdef _POSIX_THREAD_ATTR_STACKSIZE
	/* Set thread's stack size */
	if (thread->stack_size > 0) {
		rc_stack_size = pthread_attr_setstacksize(&attr, (size_t)thread->stack_size);
	}
#  endif

	/* Create the thread */
	if (! rc_stack_size) {
#  ifdef OLD_PTHREADS_API
		rc_thread_create = pthread_create(&thread->thr, attr, run_thread, (void *)thread);
#  else
#	if defined(HAS_PTHREAD_ATTR_SETSCOPE) && defined(PTHREAD_SCOPE_SYSTEM)
		pthread_attr_setscope(&attr, PTHREAD_SCOPE_SYSTEM);
#	endif
		rc_thread_create = pthread_create(&thread->thr, &attr, run_thread, (void *)thread);
#  endif
	}
	/* Now it's safe to accept signals, since we're in our own interpreter's
	 * context and we have created the thread.
	 */
	S_set_sigmask(&thread->initial_sigmask);
#endif
	return thread;
}

MODULE = threads::lite             PACKAGE = threads::lite

PROTOTYPES: DISABLED

BOOT:
    PL_threadhook = &S_mthread_hook;

	if (!global.inited) {
		MUTEX_INIT(&global.lock);
		global.inited = TRUE;
		global.count = 1;
	}


SV*
create(object, ...)
	SV* object;
	CODE:
		mthread* thread = create_thread(65536);
		queue_enqueue(thread->queue, PL_stack_base + ax + 1, items - 1);
		RETVAL = object_new(gv_stashpv("threads::lite", FALSE));
		sv_magicext(SvRV(RETVAL), NULL, PERL_MAGIC_ext, &table, (char*)thread, 0);
	OUTPUT:
		RETVAL

void
send(object, ...)
	SV* object;
	CODE:
		MAGIC* magic;
		if (!SvROK(object) || !SvMAGICAL(SvRV(object)) || !(magic = mg_find(SvRV(object), PERL_MAGIC_ext)))
			Perl_croak(aTHX_ "Something is very wrong, this is not a magic thread object\n");
		if (items == 1)
			Perl_croak(aTHX_ "Can't send an empty list\n");
		message_queue* queue = ((mthread*)magic->mg_ptr)->queue;
		queue_enqueue(queue, PL_stack_base + ax + 1, items - 1);



MODULE = threads::lite             PACKAGE = threads::lite::queue

PROTOTYPES: DISABLED

SV*
new(class)
	SV* class;
	PPCODE:
		message_queue* queue = queue_new();
		SV* ret = queue_object_new(queue, gv_stashsv(class, FALSE), FALSE);
		PUSHs(sv_2mortal(ret));

void
enqueue(object, ...)
	SV* object;
	CODE:
		message_queue* queue = get_queue_from(object);
		if (items == 1)
			Perl_croak(aTHX_ "Can't enqueue empty list\n");
		queue_enqueue(queue, PL_stack_base + ax + 1, items - 1);

void
dequeue(object)
	SV* object;
	PPCODE:
		message_queue* queue = get_queue_from(object);
		SV* values = queue_dequeue(queue);
		push_queued(values);

void
dequeue_nb(object)
	SV* object;
	PPCODE:
		message_queue* queue = get_queue_from(object);
		SV* values = queue_dequeue_nb(queue);
		if (values)
			push_queued(values);
		else
			XSRETURN_EMPTY;
