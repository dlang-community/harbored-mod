/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl., © 2015 Ferdinand Majerech
 * Authors: Brian Schott, Ferdinand Majerech
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */

/// std.allocator-compatible memory allocator.
module allocator;

public import std.allocator;
import std.stdio;


/** Allocator used by hmod (block allocator with a GC fallback for allcs bigger than block size)
 */
public alias Allocator = FallbackAllocator!(
	HmodBlockAllocator!(32 * 1024), 
	GCAllocator);


/** A somewhat incomplete (no dealloc) std.allocator implementation - passed to
 * libdparse.
 *
 * All data is deallocated in destructor.
 *
 * Allocates memory in fixed-size blocks and tries to place allocations into
 * those blocks. Allocations larger than a block fail.
 *
 * Based on BlockAllocator from Brian Schott's containers library
 */
struct HmodBlockAllocator(size_t blockSize)
{
	union
	{
		private size_t bytesAllocated_;
		/// Number of bytes allocated over time.
		const size_t bytesAllocated;
	}
	// Since we don't support deallocation (right now), these two are the same
	/// The highest number of bytes allocated at any given moment.
	alias bytesHighTide = bytesAllocated;
	union 
	{
		private size_t bytesWithSlack_;
		/// Number of bytes allocated at the moment, including slack (wasted space)
		const size_t bytesWithSlack;
	}
	union 
	{
		private size_t bytesGivenUp_;
		/// Total size of allocations that failed (bigger than block size).
		const size_t bytesGivenUp;
	}
	union 
	{
		private size_t allocsGivenUp_;
		/// Number of allocations that failed.
		const size_t allocsGivenUp;
	}
	union 
	{
		private size_t bytesAttemptedToDeallocate_;
		/// Number of bytes the user has attempted to deallocate.
		const size_t bytesAttemptedToDeallocate;
	}
	/**
	 * Copy construction disabled because this struct clears its memory with a
	 * destructor.
	 */
	@disable this(this);

	/**
	 * Frees all memory allocated by this allocator
	 */
	~this() pure nothrow @trusted
	{
		Node* current = root;
		Node* previous = void;
		while (current !is null)
		{
			previous = current;
			current = current.next;
			assert (previous == previous.memory.ptr);
			Mallocator.it.deallocate(previous.memory);
		}
		root = null;
	}

	/**
	 * Standard allocator operation.
	 *
	 * Returns null if bytes > blockSize.
	 */
	void[] allocate(size_t bytes) pure nothrow @trusted
	out (result)
	{
		import std.string;
		assert (result is null || result.length == bytes,
			format("Allocated %d bytes when %d bytes were requested.",
			       result.length, bytes));
	}
	body
	{
		void updateStats(void[] result)
		{
			if(result is null) 
			{
				++allocsGivenUp_;
				bytesGivenUp_ += bytes;
				return;
			}
			bytesAllocated_ += result.length;
		}
		if(bytes > maxAllocationSize) 
		{
			import std.exception;
			debug writeln("Big alloc: ", bytes).assumeWontThrow;
			updateStats(null);
			return null; 
		}

		// Allocate from the beginning of the list. Filled blocks go later in
		// the list.
		// Give up after three blocks. We don't want to do a full linear scan.
		size_t i = 0;
		for (Node* current = root; current !is null && i < 3; current = current.next)
		{
			void[] mem = allocateInNode(current, bytes);
			if (mem !is null)
			{
				updateStats(mem);
				return mem;
			}
			i++;
		}
		Node* n = allocateNewNode();
		bytesWithSlack_ += n.memory.length;
		void[] mem = allocateInNode(n, bytes);
		n.next = root;
		root = n;
		updateStats(mem);
		return mem;
	}

	//TODO implement deallocate if/when libdparse uses it (needs allocator design changes)
	/// Dummy deallocation function, to keep track of how much the user tried to deallocate.
	void deallocate(void[] b) pure nothrow @trusted
	{
		bytesAttemptedToDeallocate_ += b.length;
	}

	/// Was the given buffer allocated with this allocator?
	bool owns(void[] b) const pure nothrow @trusted
	{
		for(const(Node)* current = root; current !is null; current = current.next)
		{
			if(b.ptr >= current.memory.ptr && 
			   b.ptr + b.length <= current.memory.ptr + current.used)
			{
				return true;
			}
		}
		return false;
	}
	/**
	 * The maximum number of bytes that can be allocated at a time with this
	 * allocator. This is smaller than blockSize because of some internal
	 * bookkeeping information.
	 */
	enum maxAllocationSize = blockSize - Node.sizeof;

	/**
	 * Allocator's memory alignment
	 */
	enum alignment = platformAlignment;

	/// Write allocation statistics to standard output.
	void writeStats()
	{
		writefln("allocated: %.2fMiB\n"
		         "deallocate attempts: %.2fMiB\n"
		         "high tide: %.2f\n"
		         "allocated + slack: %.2f\n"
		         "given up (bytes): %.2f\n" 
		         "given up (allocs): %s\n",
		         bytesAllocated / 1000_000.0,
		         bytesAttemptedToDeallocate_ / 1000_000.0,
		         bytesHighTide / 1000_000.0,
		         bytesWithSlack / 1000_000.0,
		         bytesGivenUp / 1000_000.0,
		         allocsGivenUp);
	}
private:

	/**
	 * Allocates a new node along with its memory
	 */
	Node* allocateNewNode() pure nothrow const @trusted
	{
		void[] memory = Mallocator.it.allocate(blockSize);
		Node* n = cast(Node*) memory.ptr;
		n.used = roundUpToMultipleOf(Node.sizeof, platformAlignment);
		n.memory = memory;
		n.next = null;
		return n;
	}

	/**
	 * Allocates memory from the given node
	 */
	void[] allocateInNode(Node* node, size_t bytes) pure nothrow const @safe
	in
	{
		assert (node !is null);
	}
	body
	{
		if (node.used + bytes > node.memory.length)
			return null;
		immutable prev = node.used;
		node.used = roundUpToMultipleOf(node.used + bytes, platformAlignment);
		return node.memory[prev .. prev + bytes];
	}

	/**
	 * Single linked list of allocated blocks
	 */
	static struct Node
	{
		void[] memory;
		size_t used;
		Node* next;
	}

	/**
	 * Pointer to the first item in the node list
	 */
	Node* root;

	/**
	 * Returns s rounded up to a multiple of base.
	 */
	static size_t roundUpToMultipleOf(size_t s, uint base) pure nothrow @safe
	{
		assert(base);
		auto rem = s % base;
		return rem ? s + base - rem : s;
	}
}
