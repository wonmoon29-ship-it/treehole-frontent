import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "匿名树洞",
  description: "完全匿名的纯文字树洞",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      {/* 
        这里剥离了所有 next/font 外部请求。
        antialiased 用于开启系统级别的字体抗锯齿平滑。
        font-sans 会让浏览器自动调用当前操作系统的底层默认无衬线字体 (如 Windows 的微软雅黑/苹方，Mac 的 San Francisco)
      */}
      <body className="font-sans antialiased">
        {children}
      </body>
    </html>
  );
}