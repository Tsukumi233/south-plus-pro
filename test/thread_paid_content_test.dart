import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:south_plus_rewrite/features/thread/thread_detail_screen.dart';
import 'package:south_plus_rewrite/features/thread/thread_post_body.dart';
import 'package:south_plus_rewrite/features/thread/thread_render_models.dart';
import 'package:south_plus_rewrite/models/forum_models.dart';
import 'package:south_plus_rewrite/services/forum_repository.dart';
import 'package:south_plus_rewrite/services/parsers/thread_content_parser.dart';
import 'package:south_plus_rewrite/services/parsers/thread_detail_parser.dart';

const _downloadUrl = 'https://pan.baidu.com/s/example?pwd=abcd';
const _buyPath = 'job.php?action=buytopic&tid=1&pid=tpc';

void main() {
  for (final price in [5, 0]) {
    test('preserves unlocked $price SP content and links in inline segments',
        () {
      final document = html_parser.parse(_postHtml(price: price));
      final segments = ThreadContentParser().extractInlineSegments(
        document.querySelector('#read_tpc')!,
      );
      final content = _allSegments(segments).toList();

      expect(content.map((segment) => segment.text).join(),
          contains('提取码: abcd 解压码: example'));
      expect(content.where((segment) => segment.href == _downloadUrl),
          hasLength(1));
      expect(content.where((segment) => segment.saleBox != null), isEmpty);
      expect(content.map((segment) => segment.text).join(), contains('公开正文'));
    });

    test(
        'desktop $price SP post retains unlocked body and download render block',
        () {
      final document = html_parser.parse(_postHtml(price: price));
      final reply = ThreadDetailParser().desktopThreadCards(document).single;
      final model = ThreadPostRenderModel.fromSegments(reply.segments);

      expect(reply.content, contains('提取码: abcd 解压码: example'));
      expect(reply.links.single.url, _downloadUrl);
      expect(reply.saleBoxes, isEmpty);
      expect(model.hasSaleBoxes, isFalse);
      final blocks = _allBlocks(model).toList();
      expect(
          blocks.whereType<ThreadLinkRenderBlock>().single.url, _downloadUrl);
      expect(
          blocks.whereType<ThreadTextRenderBlock>().map((b) => b.text).join(),
          contains('提取码: abcd 解压码: example'));
    });
  }

  test('desktop post with only unlocked content is still rendered', () {
    final document = html_parser.parse(_postHtml(publicBody: ''));
    final reply = ThreadDetailParser().desktopThreadCards(document).single;
    final segments = _allSegments(reply.segments).toList();

    expect(segments.where((segment) => segment.href == _downloadUrl),
        hasLength(1));
    expect(
        segments.map((segment) => segment.text).join(), contains('提取码: abcd'));
  });

  test('unlocked content preserves image and text after the sale heading', () {
    final document = html_parser.parse(_postHtml(
      unlockedContent: '购买后的正文<br><img src="https://example.com/image.png">',
    ));
    final reply = ThreadDetailParser().desktopThreadCards(document).single;
    final segments = _allSegments(reply.segments).toList();

    expect(segments.map((segment) => segment.text).join(), contains('购买后的正文'));
    expect(
        segments
            .where((segment) => segment.url == 'https://example.com/image.png'),
        hasLength(1));
    expect(reply.saleBoxes, isEmpty);
  });

  test('locked content keeps one purchase action and its warning', () {
    final document = html_parser.parse(_postHtml(locked: true));
    final reply = ThreadDetailParser().desktopThreadCards(document).single;
    final model = ThreadPostRenderModel.fromSegments(reply.segments);

    expect(reply.saleBoxes.single.buyPath, _buyPath);
    expect(reply.saleBoxes.single.warning, '购买风险提示');
    expect(reply.saleBoxes.single.price, 5);
    expect(model.blocks.whereType<ThreadSaleBoxRenderBlock>(), hasLength(1));
    expect(model.hasQuotes, isFalse);
    expect(reply.content, '公开正文');
    expect(reply.links, isEmpty);
  });

  testWidgets('purchase refresh reveals the unlocked link and passwords',
      (tester) async {
    final repository = _PaidThreadRepository();
    await tester.pumpWidget(MaterialApp(
      home: ThreadDetailScreen(
        thread: _PaidThreadRepository.thread,
        repository: repository,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('购买查看'), findsOneWidget);
    expect(find.text(_downloadUrl, findRichText: true), findsNothing);
    await tester.ensureVisible(find.text('购买查看'));
    await tester.tap(find.text('购买查看'));
    await tester.pumpAndSettle();

    expect(repository.purchasePaths, [_buyPath]);
    expect(repository.fetchCount, 2);
    expect(find.text('购买查看'), findsNothing);
    expect(find.text(_downloadUrl, findRichText: true), findsOneWidget);
    expect(
        find.textContaining('提取码: abcd', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unlocked post displays its download link and passwords',
      (tester) async {
    final document = html_parser.parse(_postHtml());
    final reply = ThreadDetailParser().desktopThreadCards(document).single;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThreadPostBody(
          content: reply.content,
          quote: reply.quote,
          images: reply.images,
          links: reply.links,
          saleBoxes: reply.saleBoxes,
          saleBoxesFirst: reply.saleBoxesFirst,
          segments: reply.segments,
          buyingSaleBoxes: const {},
          onBuySaleBox: (_) =>
              fail('An unlocked post must not request purchase'),
        ),
      ),
    ));

    expect(find.text(_downloadUrl, findRichText: true), findsOneWidget);
    expect(
        find.textContaining('提取码: abcd', findRichText: true), findsOneWidget);
    expect(find.text('购买查看'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _PaidThreadRepository extends ForumRepository {
  static const thread = ForumThread(
    title: '测试出售帖',
    url: 'https://south-plus.net/read.php?tid-1.html',
    replies: 0,
    section: '茶馆',
  );

  final purchasePaths = <String>[];
  int fetchCount = 0;

  @override
  Future<ThreadDetail> fetchThreadDetail(ForumThread thread,
      {int page = 1}) async {
    fetchCount++;
    final document =
        html_parser.parse(_postHtml(locked: purchasePaths.isEmpty));
    final post = ThreadDetailParser().desktopThreadCards(document).single;
    return ThreadDetail(
      thread: thread,
      body: post.content,
      bodySegments: post.segments,
      bodyLinks: post.links,
      bodySaleBoxes: post.saleBoxes,
      bodySaleBoxesFirst: post.saleBoxesFirst,
      replies: const [],
    );
  }

  @override
  Future<ReplyResult> buySaleBox(ThreadSaleBox saleBox) async {
    purchasePaths.add(saleBox.buyPath);
    return const ReplyResult(success: true, message: '购买完成');
  }
}

Iterable<ThreadContentSegment> _allSegments(
    List<ThreadContentSegment> segments) sync* {
  for (final segment in segments) {
    yield segment;
    yield* _allSegments(segment.children);
  }
}

Iterable<ThreadRenderBlock> _allBlocks(ThreadPostRenderModel model) sync* {
  for (final block in model.blocks) {
    yield block;
    if (block is ThreadQuoteRenderBlock) {
      yield* _allBlocks(block.renderModel);
    }
  }
}

// The forum reuses the blockquote after the sale heading for both the locked
// warning and the unlocked content shown in issue #8. Only locked posts have
// a buy button; unlocked posts may still show their price and buyer count.
String _postHtml({
  int price = 5,
  bool locked = false,
  String publicBody = '公开正文',
  String? unlockedContent,
}) {
  final buyButton = locked
      ? '<input type="button" onclick="location.href=\'$_buyPath\'">'
      : '';
  final saleContent = locked
      ? '购买风险提示'
      : unlockedContent ??
          '百度网盘链接: <a href="$_downloadUrl">$_downloadUrl</a><br>'
              '提取码: abcd 解压码: example';
  return '''
    <table class="js-post"><tr>
      <th class="r_two">
        <a href="u.php?action-show-uid-123.html"><strong>Alice</strong></a>
      </th>
      <th class="r_one">
        <div class="tpc_content"><div class="f14" id="read_tpc">
          <h6 class="quote jumbotron">
            <span class="s3 f12 fn">此帖售价 $price SP币,已有 21 人购买</span>
            $buyButton
          </h6>
          <blockquote class="blockquote jumbotron">$saleContent</blockquote>
          $publicBody
        </div></div>
      </th>
    </tr></table>
  ''';
}
