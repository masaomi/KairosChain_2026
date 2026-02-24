'use client';

import Link from 'next/link';
import Header from '@/components/layout/Header';
import { ArrowLeft } from 'lucide-react';

export default function PrivacyPage() {
  return (
    <div className="min-h-screen bg-gradient-to-b from-[#1a0a2e] via-[#16213e] to-[#0f3460] relative">
      {/* Background decoration */}
      <div className="fixed inset-0 pointer-events-none">
        <div className="absolute top-20 right-20 w-72 h-72 bg-[#50c878]/5 rounded-full blur-3xl animate-pulse-slow" />
        <div className="absolute bottom-20 left-20 w-96 h-96 bg-[#d4af37]/5 rounded-full blur-3xl animate-pulse-slow" />
      </div>

      <Header />

      <main className="relative z-10 max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-8 sm:py-12">
        {/* Back Button */}
        <Link
          href="/"
          className="inline-flex items-center gap-2 text-[#d4af37] hover:text-[#e8c547] mb-8 transition-colors"
        >
          <ArrowLeft className="w-4 h-4" />
          戻る
        </Link>

        {/* Page Title */}
        <h1 className="text-3xl sm:text-4xl font-serif font-bold text-[#d4af37] mb-8">
          プライバシーポリシー
        </h1>

        {/* Content */}
        <div className="glass-morphism rounded-2xl p-6 sm:p-10 prose prose-invert max-w-none">
          <div className="space-y-6 text-[#f5f5f5]">
            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                1. 情報の収集
              </h2>
              <p className="text-base leading-relaxed">
                Echoriaは、サービス提供のため以下の情報を収集します：
              </p>
              <ul className="list-disc list-inside text-base leading-relaxed mt-2 space-y-1">
                <li>ユーザー登録時の名前、メールアドレス、パスワード</li>
                <li>エコー育成に関する行動データと選択履歴</li>
                <li>チャット履歴および会話内容</li>
                <li>デバイス情報、IPアドレス</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                2. 情報の使用目的
              </h2>
              <p className="text-base leading-relaxed">
                収集した情報は以下の目的で使用されます：
              </p>
              <ul className="list-disc list-inside text-base leading-relaxed mt-2 space-y-1">
                <li>サービスの提供・改善</li>
                <li>ユーザーサポートの提供</li>
                <li>セキュリティ管理と不正防止</li>
                <li>サービスの分析と最適化</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                3. 情報の保護
              </h2>
              <p className="text-base leading-relaxed">
                Echoriaは、ユーザー情報を保護するため、
                業界標準の暗号化およびセキュリティ対策を実施しています。
                ただし、インターネット上の送信の完全な安全性は保証されません。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                4. 第三者への共有
              </h2>
              <p className="text-base leading-relaxed">
                当社は、ユーザーの明示的な同意なく、
                個人情報を第三者と共有しません。
                ただし、法的要求または利用規約違反の場合は例外とします。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                5. クッキーと追跡技術
              </h2>
              <p className="text-base leading-relaxed">
                本サービスは、セッション管理および分析の目的で
                クッキーおよび同様の追跡技術を使用します。
                ユーザーはブラウザ設定でクッキーを制限できます。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                6. ユーザーの権利
              </h2>
              <p className="text-base leading-relaxed">
                ユーザーは、自身の個人情報について以下の権利を有しています：
              </p>
              <ul className="list-disc list-inside text-base leading-relaxed mt-2 space-y-1">
                <li>情報へのアクセス権</li>
                <li>情報の修正権</li>
                <li>情報の削除要求権</li>
                <li>処理の中止を求める権利</li>
              </ul>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                7. ポリシーの変更
              </h2>
              <p className="text-base leading-relaxed">
                当社は、本ポリシーをいつでも変更する権利を有します。
                重大な変更は、メール通知により告知されます。
                本ページの継続使用は、変更への同意を意味します。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                8. お問い合わせ
              </h2>
              <p className="text-base leading-relaxed">
                本ポリシーに関するご質問やご懸念については、
                privacy@echoria.app までご連絡ください。
              </p>
            </section>

            <section className="pt-6 border-t border-white/10">
              <p className="text-sm text-[#b0b0b0]">
                最終更新日: 2026年2月24日
              </p>
            </section>
          </div>
        </div>
      </main>
    </div>
  );
}
