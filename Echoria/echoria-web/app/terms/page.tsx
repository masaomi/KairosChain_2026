'use client';

import Link from 'next/link';
import Header from '@/components/layout/Header';
import { ArrowLeft } from 'lucide-react';

export default function TermsPage() {
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
          利用規約
        </h1>

        {/* Content */}
        <div className="glass-morphism rounded-2xl p-6 sm:p-10 prose prose-invert max-w-none">
          <div className="space-y-6 text-[#f5f5f5]">
            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                1. サービスについて
              </h2>
              <p className="text-base leading-relaxed">
                本サービス「Echoria」は、ユーザーがAIガイド「エコー」を育成し、
                物語を通じて相互作用する対話的なプラットフォームです。
                本規約は、本サービスの利用に関する条件を定めています。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                2. 利用者の責任
              </h2>
              <p className="text-base leading-relaxed">
                ユーザーは、本サービスを適切かつ合法的に利用することに同意します。
                違法、有害、または不適切なコンテンツの作成・共有は禁止されています。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                3. 知的財産権
              </h2>
              <p className="text-base leading-relaxed">
                本サービスのコンテンツ、設計、およびすべての関連要素は、
                著作権法によって保護されています。ユーザーは、
                個人的な使用以外の目的でコンテンツを複製することはできません。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                4. サービスの変更
              </h2>
              <p className="text-base leading-relaxed">
                当社は、予告なくサービスの内容を変更または停止する権利を有します。
                これにより生じた損害については、当社は責任を負いません。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                5. 免責事項
              </h2>
              <p className="text-base leading-relaxed">
                本サービスは「現状のまま」提供されます。
                当社は、サービスの継続性、安全性、正確性について
                いかなる保証も行いません。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                6. 利用規約の変更
              </h2>
              <p className="text-base leading-relaxed">
                当社は、いつでも本規約を変更する権利を有します。
                変更は本ページに掲載された時点で有効となります。
                継続使用は、変更内容への同意を意味します。
              </p>
            </section>

            <section>
              <h2 className="text-2xl font-serif font-bold text-[#d4af37] mb-4">
                7. 准拠法
              </h2>
              <p className="text-base leading-relaxed">
                本規約は、日本国の法律に準拠します。
                本規約に関する紛争は、日本の裁判所の管轄に服します。
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
