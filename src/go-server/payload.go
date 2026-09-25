package main

type PayloadStore struct {
	preallocate bool
	buf1K       []byte
	buf64K      []byte
	buf1M       []byte
}

func NewPayloadStore(preallocate bool) *PayloadStore {
	store := &PayloadStore{
		preallocate: preallocate,
		buf1K:       make([]byte, 1024),
		buf64K:      make([]byte, 65536),
		buf1M:       make([]byte, 1048576),
	}

	for i := range store.buf1K {
		store.buf1K[i] = byte(i % 251)
	}
	for i := range store.buf64K {
		store.buf64K[i] = byte(i % 251)
	}
	for i := range store.buf1M {
		store.buf1M[i] = byte(i % 251)
	}

	return store
}

func (p *PayloadStore) Get(size int) ([]byte, bool) {
	var staticBuf []byte
	switch size {
	case 1024:
		staticBuf = p.buf1K
	case 65536:
		staticBuf = p.buf64K
	case 1048576:
		staticBuf = p.buf1M
	default:
		return nil, false
	}

	if p.preallocate {
		return staticBuf, true
	}

	// Contract §2a secondary experiment: allocate dynamic buffer per request
	dynamicBuf := make([]byte, size)
	for i := range dynamicBuf {
		dynamicBuf[i] = byte(i % 251)
	}
	return dynamicBuf, true
}
