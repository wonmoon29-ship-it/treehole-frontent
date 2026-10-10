"use client";

import { useState, useEffect, useRef, FormEvent } from "react";
import { supabase } from "../lib/supabase";
import { deriveTripcodeKey } from "../lib/tripcode";

// 号码 (display_id) 直接存在帖子 / 回复上；作者 token 不再通过 API 暴露
interface Reply {
  id: string;
  content: string;
  created_at: string;
  display_id: number;
}

interface Post {
  id: string;
  content: string;
  created_at: string;
  display_id: number;
  replies: Reply[];
}

// 数据库函数里主动抛出的提示（如“内容不能超过 200 字”）直接展示给用户，其余统一用通用提示
function describeError(error: unknown): string {
  const e = error as { code?: string; message?: string } | null;
  if (e?.message && (e.code === "P0001" || e.code === "22023")) {
    return `：${e.message}`;
  }
  return "，请稍后再试";
}

export default function Home() {
  const [posts, setPosts] = useState<Post[]>([]);
  const [content, setContent] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);

  // 绊码 (身份暗号) 状态：保存在内存中，刷新网页即刻灰飞烟灭
  const [tripcode, setTripcode] = useState("");
  // 缓存最近一次的派生结果，连续发言时不必重复做 PBKDF2 计算
  const derivedKeyRef = useRef<{ secret: string; key: string } | null>(null);

  const [activeReplyPostId, setActiveReplyPostId] = useState<string | null>(null);
  const [replyContent, setReplyContent] = useState("");
  const [isReplying, setIsReplying] = useState(false);

  useEffect(() => {
    fetchPosts();
    // 启动时彻底清理旧版的缓存，斩草除根
    localStorage.removeItem("pisces_author_token"); 
  }, []);

  async function fetchPosts() {
    const { data, error } = await supabase
      .from("posts")
      .select(`
        id, content, created_at, display_id,
        replies ( id, content, created_at, display_id )
      `)
      .order("created_at", { ascending: false });

    if (error) {
      console.error("获取帖子失败:", error);
    } else {
      const formattedData = ((data ?? []) as unknown as Post[]).map((post) => ({
        ...post,
        replies: [...(post.replies ?? [])].sort(
          (a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime(),
        ),
      }));
      setPosts(formattedData);
    }
  }

  // 身份的核心逻辑：只把暗号的派生密钥交给服务端，由数据库用私密 pepper 算出真正的身份
  // 返回 null 表示没填暗号，即一次性路人
  async function getTripcodeKey(): Promise<string | null> {
    const secret = tripcode.trim();
    if (!secret) return null;
    if (derivedKeyRef.current?.secret !== secret) {
      derivedKeyRef.current = { secret, key: await deriveTripcodeKey(secret) };
    }
    return derivedKeyRef.current.key;
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!content.trim()) return;
    setIsSubmitting(true);
    try {
      const key = await getTripcodeKey();
      const { error } = await supabase.rpc("create_post", { p_content: content, p_key: key });
      if (error) throw error;
      setContent("");
      fetchPosts();
    } catch (error) {
      console.error("发帖出错:", error);
      alert(`发帖失败${describeError(error)}`);
    } finally {
      setIsSubmitting(false);
    }
  }

  async function handleReplySubmit(e: FormEvent, postId: string) {
    e.preventDefault();
    if (!replyContent.trim()) return;
    setIsReplying(true);
    try {
      const key = await getTripcodeKey();
      const { error } = await supabase.rpc("create_reply", {
        p_post_id: postId,
        p_content: replyContent,
        p_key: key,
      });
      if (error) throw error;
      setReplyContent("");
      setActiveReplyPostId(null);
      fetchPosts();
    } catch (error) {
      console.error("回复出错:", error);
      alert(`回复失败${describeError(error)}`);
    } finally {
      setIsReplying(false);
    }
  }

  return (
    <main className="min-h-screen bg-gray-50 p-4 md:p-12 font-sans text-gray-800">
      <div className="max-w-2xl mx-auto space-y-8">
        
        <header className="text-center space-y-3">
          <h1 className="text-3xl font-bold text-gray-900">匿名树洞</h1>
          <p className="text-gray-500 text-sm">完全匿名，首次发言即分配专属代号</p>
          <div className="inline-block bg-gray-100 px-4 py-2 rounded-md border border-gray-200 mt-2">
             <p className="text-xs text-gray-500 flex items-center justify-center gap-1">
               <svg xmlns="http://www.w3.org/2000/svg" className="h-4 w-4 text-gray-400" viewBox="0 0 20 20" fill="currentColor">
                 <path fillRule="evenodd" d="M2.166 4.999A11.954 11.954 0 0010 1.944 11.954 11.954 0 0017.834 5c.11.65.166 1.32.166 2.001 0 5.225-3.34 9.67-8 11.317C5.34 16.67 2 12.225 2 7c0-.682.057-1.35.166-2.001zm11.541 3.708a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clipRule="evenodd" />
               </svg>
               如高度在意隐私，建议通过代理软件（如 Tor / VPN）改变网络路由环境后再进行访问。
             </p>
          </div>
        </header>

        {/* 核心改动：身份识别区 (绊码输入框) */}
        <div className="bg-white p-4 rounded-xl shadow-sm border border-gray-100 flex items-center gap-3">
          <label className="text-sm font-medium text-gray-700 whitespace-nowrap">身份暗号</label>
          <input
            type="password"
            value={tripcode}
            onChange={(e) => setTripcode(e.target.value)}
            placeholder="留空则为一次性路人。输入同一暗号即可保持同一代号。"
            className="flex-1 p-2 bg-gray-50 border border-gray-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-gray-300 text-sm"
          />
        </div>

        {/* 主帖输入框 */}
        <form onSubmit={handleSubmit} className="bg-white p-4 rounded-xl shadow-sm border border-gray-100">
          <textarea
            value={content}
            onChange={(e) => setContent(e.target.value)}
            placeholder="写下你想说的话..."
            className="w-full p-3 bg-gray-50 border border-gray-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-gray-300 resize-none h-32"
            maxLength={200}
          />
          <div className="flex justify-between items-center mt-3">
            <span className={`text-sm ${content.length >= 200 ? 'text-red-500 font-bold' : 'text-gray-400'}`}>
              {content.length}/200
            </span>
            <button
              type="submit"
              disabled={isSubmitting || !content.trim()}
              className="bg-black text-white px-6 py-2 rounded-lg font-medium hover:bg-gray-800 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
            >
              {isSubmitting ? "发送中..." : "发送"}
            </button>
          </div>
        </form>

        <div className="space-y-6">
          {posts.map((post) => (
            <div key={post.id} className="bg-white p-5 rounded-xl shadow-sm border border-gray-100">
              
              <div className="flex justify-between items-center mb-3">
                <span className="font-bold text-gray-900">
                  匿名网友 {post.display_id}
                </span>
                <span className="text-xs text-gray-400">
                  {new Date(post.created_at).toLocaleString()}
                </span>
              </div>
              <p className="text-gray-700 whitespace-pre-wrap leading-relaxed mb-4">
                {post.content}
              </p>

              {post.replies && post.replies.length > 0 && (
                <div className="mt-4 pl-4 border-l-2 border-gray-100 space-y-3">
                  {post.replies.map((reply) => (
                    <div key={reply.id} className="bg-gray-50 p-3 rounded-lg text-sm">
                      <div className="flex justify-between items-center mb-1">
                        <span className="font-semibold text-gray-700">
                          匿名网友 {reply.display_id}
                        </span>
                        <span className="text-xs text-gray-400">
                          {new Date(reply.created_at).toLocaleString()}
                        </span>
                      </div>
                      <p className="text-gray-600">{reply.content}</p>
                    </div>
                  ))}
                </div>
              )}

              <div className="mt-4 pt-3 border-t border-gray-50 flex justify-end">
                <button 
                  onClick={() => setActiveReplyPostId(activeReplyPostId === post.id ? null : post.id)}
                  className="text-sm text-gray-500 hover:text-black font-medium transition-colors"
                >
                  {activeReplyPostId === post.id ? "取消回复" : "回复"}
                </button>
              </div>

              {/* 回复输入框 */}
              {activeReplyPostId === post.id && (
                <form onSubmit={(e) => handleReplySubmit(e, post.id)} className="mt-3 flex gap-2 items-center">
                  <input
                    type="text"
                    value={replyContent}
                    onChange={(e) => setReplyContent(e.target.value)}
                    placeholder="写下你的回复..."
                    className="flex-1 p-2 bg-gray-50 border border-gray-200 rounded-lg focus:outline-none focus:ring-2 focus:ring-gray-300 text-sm"
                    maxLength={200}
                    autoFocus
                  />
                  <span className={`text-xs w-12 text-right ${replyContent.length >= 200 ? 'text-red-500 font-bold' : 'text-gray-400'}`}>
                    {replyContent.length}/200
                  </span>
                  <button
                    type="submit"
                    disabled={isReplying || !replyContent.trim()}
                    className="bg-gray-800 text-white px-4 py-2 rounded-lg text-sm font-medium hover:bg-black disabled:opacity-50"
                  >
                    {isReplying ? "..." : "发送"}
                  </button>
                </form>
              )}

            </div>
          ))}
          
          {posts.length === 0 && (
            <div className="text-center text-gray-400 py-12">
              还没有人留言，来做第一个发言的人吧。
            </div>
          )}
        </div>

      </div>
    </main>
  );
}