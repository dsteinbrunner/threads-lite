#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"

#include "message.h"
#include "queue.h"

/*
 * Message queues
 */

struct queue_node {
	message message;
	struct queue_node* next;
};

static void node_unshift(queue_node** position, queue_node* new_node) {
	new_node->next = *position;
	*position = new_node;
}

static queue_node* node_shift(queue_node** position) {
	queue_node* ret = *position;
	*position = (*position)->next;
	return ret;
}

static void node_push(queue_node** end, queue_node* new_node) {
	queue_node** cur = end;
	while(*cur)
		cur = &(*cur)->next;
	*end = *cur = new_node;
	new_node->next = NULL;
}

static void node_destroy(struct queue_node* current) {
	while (current != NULL) {
		struct queue_node* next = current->next;
		message_destroy(&current->message);
		PerlMemShared_free(current);
		current = next;
	}
}

void queue_init(message_queue* queue) {
	MUTEX_INIT(&queue->mutex);
	COND_INIT(&queue->condvar);
}

void queue_enqueue(message_queue* queue, message* message_, perl_mutex* external_lock) {
	MUTEX_LOCK(&queue->mutex);
	if (external_lock)
		MUTEX_UNLOCK(external_lock);

	queue_node* new_entry;
	if (queue->reserve)
		new_entry = node_shift(&queue->reserve);
	else
		new_entry = PerlMemShared_calloc(1, sizeof *new_entry);

	Copy(message_, &new_entry->message, 1, message);
	Zero(message_, 1, message);
	new_entry->next = NULL;

	node_push(&queue->back, new_entry);
	if (queue->front == NULL)
		queue->front = queue->back;

	COND_SIGNAL(&queue->condvar);
	MUTEX_UNLOCK(&queue->mutex);
}

static void queue_shift(message_queue* queue, message* input) {
	queue_node* front = node_shift(&queue->front);
	Copy(&front->message, input, 1, message);
	Zero(&front->message, 1, message);
	node_unshift(&queue->reserve, front);

	if (queue->front == NULL)
		queue->back = NULL;
}

void queue_dequeue(message_queue* queue, message* input, perl_mutex* external_lock) {
	MUTEX_LOCK(&queue->mutex);
	if (external_lock)
		MUTEX_UNLOCK(external_lock);

	while (!queue->front)
		COND_WAIT(&queue->condvar, &queue->mutex);

	queue_shift(queue, input);

	MUTEX_UNLOCK(&queue->mutex);
}

bool queue_dequeue_nb(message_queue* queue, message* input, perl_mutex* external_lock) {
	MUTEX_LOCK(&queue->mutex);
	if (external_lock)
		MUTEX_UNLOCK(external_lock);

	if (queue->front) {
		queue_shift(queue, input);

		MUTEX_UNLOCK(&queue->mutex);
		return TRUE;
	}
	else {
		MUTEX_UNLOCK(&queue->mutex);
		return FALSE;
	}
}

void queue_destroy(message_queue* queue) {
	MUTEX_LOCK(&queue->mutex);
	queue_node* next;
	node_destroy(queue->front);
	node_destroy(queue->reserve);
	COND_DESTROY(&queue->condvar);
	MUTEX_UNLOCK(&queue->mutex);
	MUTEX_DESTROY(&queue->mutex);
}
