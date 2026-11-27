import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_domain_drive_client/shared/cache/thumbnail_request_scheduler.dart';

void main() {
  test('在途任务不超过并发上限，其余排队等待', () async {
    final scheduler = ThumbnailRequestScheduler(maxConcurrency: 2);
    final started = <String>[];
    final gates = <String, Completer<void>>{};

    Future<List<int>?> submit(String key) {
      gates[key] = Completer<void>();
      return scheduler.run(key, () async {
        started.add(key);
        await gates[key]!.future;
        return <int>[key.codeUnitAt(0)];
      });
    }

    final futures = <Future<List<int>?>>[
      for (final key in <String>['a', 'b', 'c', 'd', 'e']) submit(key),
    ];

    expect(scheduler.inFlight, 2);
    expect(scheduler.pending, 3);
    expect(started, <String>['a', 'b']);

    gates['a']!.complete();
    await futures[0];
    await Future<void>.delayed(Duration.zero);

    expect(scheduler.inFlight, 2);
    // 后进先出：最新排队的 e 先于 c、d 分发。
    expect(started, <String>['a', 'b', 'e']);

    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await Future.wait(futures);
    expect(scheduler.inFlight, 0);
    expect(scheduler.pending, 0);
  });

  test('同一键的并发请求只执行一次并共享结果', () async {
    final scheduler = ThumbnailRequestScheduler(maxConcurrency: 2);
    var runs = 0;
    final gate = Completer<void>();

    Future<List<int>?> task() async {
      runs++;
      await gate.future;
      return <int>[7, 8, 9];
    }

    final first = scheduler.run('k', task);
    final second = scheduler.run('k', task);

    expect(runs, 1);
    gate.complete();

    expect(await first, <int>[7, 8, 9]);
    expect(await second, <int>[7, 8, 9]);
    expect(runs, 1);
  });

  test('LIFO 分发：最新请求优先启动', () async {
    final scheduler = ThumbnailRequestScheduler(maxConcurrency: 1);
    final started = <String>[];
    final gates = <String, Completer<void>>{
      'a': Completer<void>(),
      'b': Completer<void>(),
      'c': Completer<void>(),
    };

    Future<List<int>?> submit(String key) {
      return scheduler.run(key, () async {
        started.add(key);
        await gates[key]!.future;
        return <int>[1];
      });
    }

    final fa = submit('a');
    final fb = submit('b');
    final fc = submit('c');
    expect(started, <String>['a']);

    gates['a']!.complete();
    await fa;
    await Future<void>.delayed(Duration.zero);
    expect(started, <String>['a', 'c']);

    gates['c']!.complete();
    await fc;
    await Future<void>.delayed(Duration.zero);
    expect(started, <String>['a', 'c', 'b']);

    gates['b']!.complete();
    await fb;
  });

  test('取消排队中的任务后不再执行，Future 以 null 完成', () async {
    final scheduler = ThumbnailRequestScheduler(maxConcurrency: 1);
    final gateA = Completer<void>();
    var bRuns = 0;

    final fa = scheduler.run('a', () async {
      await gateA.future;
      return <int>[1];
    });
    final fb = scheduler.run('b', () async {
      bRuns++;
      return <int>[2];
    });

    scheduler.cancel('b');
    expect(await fb, isNull);
    expect(bRuns, 0);
    expect(scheduler.pending, 0);

    gateA.complete();
    expect(await fa, <int>[1]);
  });

  test('已开始的任务取消后仍然完成，队列继续分发', () async {
    final scheduler = ThumbnailRequestScheduler(maxConcurrency: 1);
    final gateA = Completer<void>();
    final gateB = Completer<void>();

    final fa = scheduler.run('a', () async {
      await gateA.future;
      return <int>[10];
    });
    final fb = scheduler.run('b', () async {
      await gateB.future;
      return <int>[20];
    });
    expect(scheduler.inFlight, 1);

    scheduler.cancel('a');
    gateA.complete();
    expect(await fa, <int>[10]);
    await Future<void>.delayed(Duration.zero);
    expect(scheduler.inFlight, 1);

    gateB.complete();
    expect(await fb, <int>[20]);
    expect(scheduler.inFlight, 0);
  });

  test('多订阅者共享作业时，单个取消不终止排队请求', () async {
    final scheduler = ThumbnailRequestScheduler(maxConcurrency: 1);
    final gateA = Completer<void>();
    final gateX = Completer<void>();
    var xRuns = 0;

    final fa = scheduler.run('a', () async {
      await gateA.future;
      return <int>[1];
    });
    Future<List<int>?> xTask() async {
      xRuns++;
      await gateX.future;
      return <int>[5];
    }

    final fx1 = scheduler.run('x', xTask);
    final fx2 = scheduler.run('x', xTask);
    // 其中一个订阅者（例如格子回收）取消，另一订阅者仍在等待。
    scheduler.cancel('x');
    expect(scheduler.pending, 1);

    gateA.complete();
    await fa;
    await Future<void>.delayed(Duration.zero);
    expect(xRuns, 1);

    gateX.complete();
    expect(await fx1, <int>[5]);
    expect(await fx2, <int>[5]);
  });

  test('任务异常只让该作业以 null 完成，不影响后续分发', () async {
    final scheduler = ThumbnailRequestScheduler(maxConcurrency: 1);

    final failed = scheduler.run('bad', () async {
      throw StateError('boom');
    });
    final next = scheduler.run('ok', () async => <int>[3]);

    expect(await failed, isNull);
    expect(await next, <int>[3]);
    expect(scheduler.inFlight, 0);
  });
}