'use client';

import { useState, useRef, useEffect } from 'react';
import { Send } from 'lucide-react';

interface ChatInputProps {
  onSendMessage: (message: string) => void;
  disabled?: boolean;
}

export default function ChatInput({ onSendMessage, disabled }: ChatInputProps) {
  const [message, setMessage] = useState('');
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const autoResizeTextarea = () => {
    const textarea = textareaRef.current;
    if (textarea) {
      textarea.style.height = 'auto';
      textarea.style.height = Math.min(textarea.scrollHeight, 200) + 'px';
    }
  };

  useEffect(() => {
    autoResizeTextarea();
  }, [message]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (message.trim() && !disabled) {
      onSendMessage(message);
      setMessage('');
      if (textareaRef.current) {
        textareaRef.current.style.height = 'auto';
      }
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSubmit(e as any);
    }
  };

  return (
    <form onSubmit={handleSubmit} className="flex gap-3">
      <textarea
        ref={textareaRef}
        value={message}
        onChange={(e) => setMessage(e.target.value)}
        onKeyDown={handleKeyDown}
        placeholder="ここに入力... (Enterで送信、Shift+Enterで改行)"
        disabled={disabled}
        className="flex-1 px-4 py-3 rounded-lg bg-white/5 border border-white/10 text-[#f5f5f5] placeholder-[#606060] focus:outline-none focus:border-[#d4af37]/50 focus:ring-1 focus:ring-[#d4af37]/20 transition-all resize-none min-h-12 max-h-48"
        rows={1}
      />
      <button
        type="submit"
        disabled={disabled || !message.trim()}
        className="px-4 py-3 rounded-lg bg-[#d4af37] text-[#1a0a2e] hover:bg-[#e8c547] transition-colors disabled:opacity-50 disabled:cursor-not-allowed font-semibold flex items-center gap-2 flex-shrink-0"
      >
        <Send className="w-4 h-4" />
        <span className="hidden sm:inline">送信</span>
      </button>
    </form>
  );
}
