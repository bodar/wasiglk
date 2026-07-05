import { describe, expect, test } from 'bun:test';
import { ReplayQueue, type ReplayEvent } from '../src/worker/replay-queue';

const line = (value: string): ReplayEvent => ({ type: 'line', gen: 1, window: 1, value });

describe('ReplayQueue', () => {
  test('drains recorded events in order, then returns null', () => {
    const q = new ReplayQueue([line('a'), line('b')]);
    expect(q.next()).toEqual(line('a'));
    expect(q.next()).toEqual(line('b'));
    expect(q.next()).toBeNull();
    expect(q.next()).toBeNull();
  });

  test('active reflects whether events remain', () => {
    const q = new ReplayQueue([line('a')]);
    expect(q.active).toBe(true);
    q.next();
    expect(q.active).toBe(false);
  });

  test('an empty queue is inactive from the start', () => {
    expect(new ReplayQueue().active).toBe(false);
    expect(new ReplayQueue([]).active).toBe(false);
    expect(new ReplayQueue().next()).toBeNull();
  });

  test('does not alias the caller-supplied array', () => {
    const events = [line('a')];
    const q = new ReplayQueue(events);
    events.push(line('b'));
    q.next();
    expect(q.active).toBe(false); // the later push must not have entered the queue
  });

  test('takeDeferredTimer is null while replaying and returns the deferred interval once on drain', () => {
    const q = new ReplayQueue([line('a'), line('b')]);
    q.deferTimer(1000);
    expect(q.takeDeferredTimer()).toBeNull(); // still active (2 remaining)

    q.next(); // 1 remaining, still active
    expect(q.takeDeferredTimer()).toBeNull();

    q.next(); // drained
    expect(q.takeDeferredTimer()).toEqual({ interval: 1000 });
    expect(q.takeDeferredTimer()).toBeNull(); // consumed exactly once
  });

  test('takeDeferredTimer is null on drain when no timer was deferred', () => {
    const q = new ReplayQueue([line('a')]);
    q.next();
    expect(q.takeDeferredTimer()).toBeNull();
  });

  test('a deferred timer of null (cancel) is still delivered once on drain', () => {
    const q = new ReplayQueue([line('a')]);
    q.deferTimer(1000);
    q.deferTimer(null); // latest wins
    q.next();
    expect(q.takeDeferredTimer()).toEqual({ interval: null });
    expect(q.takeDeferredTimer()).toBeNull();
  });
});
