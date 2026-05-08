"use client";

import { createContext, useCallback, useContext, useMemo, useState } from "react";

interface InviteModalValue {
  open: boolean;
  openModal: () => void;
  closeModal: () => void;
}

const InviteModalContext = createContext<InviteModalValue | null>(null);

export function InviteModalProvider({ children }: { children: React.ReactNode }) {
  const [open, setOpen] = useState(false);
  const openModal = useCallback(() => setOpen(true), []);
  const closeModal = useCallback(() => setOpen(false), []);
  const value = useMemo(
    () => ({ open, openModal, closeModal }),
    [open, openModal, closeModal],
  );
  return (
    <InviteModalContext.Provider value={value}>
      {children}
    </InviteModalContext.Provider>
  );
}

export function useInviteModal(): InviteModalValue {
  const ctx = useContext(InviteModalContext);
  if (!ctx) throw new Error("useInviteModal must be used inside InviteModalProvider");
  return ctx;
}
