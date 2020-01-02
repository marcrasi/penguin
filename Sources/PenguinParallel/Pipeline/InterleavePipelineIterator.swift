import Foundation

public struct InterleavePipelineIterator<Upstream: PipelineIteratorProtocol, Producer: PipelineIteratorProtocol>: PipelineIteratorProtocol {
    public typealias Element = Producer.Element
    public typealias Func = (Upstream.Element) throws -> Producer

    init(upstream: Upstream, workerCount: Int, cycleCount: Int, perWorkerPrefetchCount: Int, f: @escaping Func) {
        self.impl = Impl(
            upstream: upstream,
            workerCount: workerCount,
            cycleCount: cycleCount,
            perWorkerPrefetchCount: perWorkerPrefetchCount,
            f: f
        )
    }

    public mutating func next() throws -> Producer.Element? {
        while true {
            guard let worker = impl.cycle.pop() else { return nil }
            guard let nextElem = worker.buffer.pop() else {
                if impl.reinitialize(worker: worker) {
                    impl.backlog.push(worker)
                }
                if let newWorker = impl.backlog.pop() {
                    impl.cycle.push(newWorker)
                }
                continue
            }
            impl.cycle.push(worker)
            return try nextElem.get()
        }
    }

    let impl: Impl

    class Impl {

        init(upstream: Upstream, workerCount: Int, cycleCount: Int, perWorkerPrefetchCount: Int, f: @escaping Func) {
            self.upstream = upstream
            self.perWorkerPrefetchCount = perWorkerPrefetchCount
            allWorkers = [Worker]()
            allWorkers.reserveCapacity(workerCount)
            let bufferConfig = PrefetchBufferConfiguration(initialCapacity: perWorkerPrefetchCount, autoTune: false)
            for i in 0..<workerCount {
                let worker = Worker(name: "interleave-worker-\(i)", bufferConfig: bufferConfig, f: f)
                allWorkers.append(worker)
                if reinitialize(worker: worker) {
                    if i < cycleCount {
                        cycle.push(worker)
                    } else {
                        backlog.push(worker)
                    }
                }
                worker.start()
            }
        }

        deinit {
            // Cleanly shut down all workers.
            for worker in allWorkers {
                worker.waitUntilStarted()
                worker.cancel()
                worker.buffer.close()
                worker.coord.signal()
                worker.join()
            }
        }

        // Returns true if the worker has useful records to produce, false otherwise.
        func reinitialize(worker: Worker) -> Bool {
            guard upstream != nil else { return false }
            worker.buffer = PrefetchBuffer(PrefetchBufferConfiguration(initialCapacity: perWorkerPrefetchCount, autoTune: false))
            let res = Result { try upstream!.next() }
            switch res {
            case let .failure(err):
                assert(worker.buffer.push(.failure(err)), "Buffer should not be already closed!")
                worker.buffer.close()
                return true
            case let .success(elem):
                worker.inputElem = elem
                worker.coord.signal()
                if elem == nil {
                    upstream = nil
                    return false
                }
                return true
            }
        }

        var perWorkerPrefetchCount: Int
        var upstream: Upstream?
        var cycle = WorkerQueue()
        var backlog = WorkerQueue()
        var allWorkers: [Worker]
    }

    /// The worker thread waits for the `coord` signal, and then:
    ///  (1) takes `inputElem` (produced by the upstream iterator),
    ///  (2) coverts it to a `Producer` iterator,
    ///  and (3) pushes elements into the buffer `buffer`.
    /// Once this producer iterator is complete, the worker closes the buffer, and
    /// goes back and waits on `coord`.
    ///
    /// When the driver (consumer) thread wants to kick off further work, they should
    /// (1) create a new buffer (to reset it back to being open), (2) set `inputElem` to
    /// a non-nil value, and (3) signal on `coord`.
    ///
    /// The background thread can be shut down by making two operations:
    ///  (1) Close the buffer.
    ///  (2) signal on `coord`.
    final class Worker: PipelineWorkerThread {

        /// Takes a `Producer` iterator and effectively runs prefetching on it.
        func produceValues(_ itr: inout Producer) -> Bool {
            while true {
                let res = Result { try itr.next() }
                switch res {
                case let .success(elem):
                    if let elem = elem {
                        if !buffer.push(.success(elem)) {
                            return false  // Buffer has been closed.
                        }
                    } else {
                        // Reached end of iterator;
                        buffer.close()
                        return true  // Finished iterator, but expect more.
                    }
                case let .failure(err):
                    if !buffer.push(.failure(err)) {
                        return false // Buffer has been closed.
                    }
                }
            }
        }

        override func body() {
            while true {
                coord.wait()
                var elemOpt: Upstream.Element? = nil
                swap(&elemOpt, &self.inputElem)  // Attempt to avoid extra copies.
                guard let elem = elemOpt else { return }  // Done!
                switch (Result { try f(elem) }) {
                case let .failure(err):
                    if !buffer.push(.failure(err)) {
                        return  // Buffer closed; done!
                    }
                case var .success(itr):
                    if !produceValues(&itr) { return }
                }
            }
        }

        init(name: String, bufferConfig: PrefetchBufferConfiguration, f: @escaping Func) {
            self.f = f
            self.buffer = PrefetchBuffer(bufferConfig)
            super.init(name: name)
        }

        var inputElem: Upstream.Element? = nil
        var coord = DispatchSemaphore(value: 0)
        var buffer: PrefetchBuffer<Element>
        let f: Func
    }

    /// A simple queue of workers.
    ///
    /// It is implemented using two stacks.
    // TODO: optimize this implementation! (Consider using unowned
    // references if ARC operations turn out to be expensive.)
    struct WorkerQueue {
        mutating func push(_ worker: Worker) {

            pushStack.append(worker)
        }
        mutating func pop() -> Worker? {
            if popStack.isEmpty {
                if pushStack.isEmpty {
                    return nil
                }
                popStack.reserveCapacity(pushStack.count)
                while let tmp = pushStack.popLast() {
                    popStack.append(tmp)
                }
            }
            return popStack.popLast()
        }
        private var pushStack = [Worker]()
        private var popStack = [Worker]()
    }
}

public extension PipelineIteratorProtocol {
    func interleave<P: PipelineIteratorProtocol>(
        cycleCount: Int,
        workerCount: Int? = nil,
        perWorkerPrefetchCount: Int = 3,
        f: @escaping (Element) throws -> P
    ) -> InterleavePipelineIterator<Self, P> {
        return InterleavePipelineIterator(
            upstream: self,
            workerCount: workerCount ?? cycleCount * 2,
            cycleCount: cycleCount,
            perWorkerPrefetchCount: perWorkerPrefetchCount,
            f: f
        )
    }
}
