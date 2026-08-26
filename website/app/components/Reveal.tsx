"use client";

import { useEffect, useRef, useState, type ReactNode } from "react";

/**
 * Fades a section up as it enters the viewport.
 *
 * IntersectionObserver rather than a scroll listener: a scroll handler runs on
 * every frame the page moves and does its own maths to decide what is on
 * screen, which is exactly the work the browser is already doing. This wakes
 * up once per element, then unregisters.
 *
 * Motion is skipped entirely under prefers-reduced-motion, so nothing starts
 * hidden and waits for an event that never arrives.
 */
export function Reveal({
  children,
  delay = 0,
  className = ""
}: {
  children: ReactNode;
  delay?: number;
  className?: string;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [shown, setShown] = useState(false);

  useEffect(() => {
    const node = ref.current;
    if (!node) return;

    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced) {
      setShown(true);
      return;
    }

    const observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry.isIntersecting) return;
        setShown(true);
        observer.disconnect();
      },
      { threshold: 0.18, rootMargin: "0px 0px -8% 0px" }
    );

    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  return (
    <div
      ref={ref}
      className={`reveal${shown ? " in" : ""} ${className}`.trim()}
      style={delay ? { transitionDelay: `${delay}ms` } : undefined}
    >
      {children}
    </div>
  );
}
