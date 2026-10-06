import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import type { ReactNode } from 'react';

/** Route-level enter/exit. Wrap routes in <AnimatePresence mode="wait"> keyed by pathname. */
export function AnimatedPage({ children }: { children: ReactNode }) {
  const reduce = useReducedMotion();
  return (
    <motion.main
      initial={reduce ? false : { opacity: 0, y: 8 }}
      animate={{ opacity: 1, y: 0 }}
      exit={reduce ? { opacity: 0 } : { opacity: 0, y: -8 }}
      transition={{ duration: 0.2, ease: 'easeOut' }}
      className="mx-auto w-full max-w-5xl px-4 py-6"
    >
      {children}
    </motion.main>
  );
}

/** Staggered list entrance; items animate out when removed. */
export function AnimatedList<T extends { id: string }>({ items, render }: { items: T[]; render: (item: T) => ReactNode }) {
  const reduce = useReducedMotion();
  return (
    <ul className="space-y-2">
      <AnimatePresence initial={false}>
        {items.map((item, i) => (
          <motion.li
            key={item.id}
            layout={!reduce}
            initial={reduce ? false : { opacity: 0, y: 6 }}
            animate={{ opacity: 1, y: 0, transition: { delay: reduce ? 0 : Math.min(i, 8) * 0.03 } }}
            exit={{ opacity: 0 }}
          >
            {render(item)}
          </motion.li>
        ))}
      </AnimatePresence>
    </ul>
  );
}
