package errkontrak

import (
	"fmt"
	"net/url"
	"regexp"
	"strconv"
)

// PageMeta / Page — padanan common/pagination/page.ts (verbatim bentuk JSON).
type PageMeta struct {
	Page       int `json:"page"`
	Limit      int `json:"limit"`
	Total      int `json:"total"`
	TotalPages int `json:"totalPages"`
}

type Page[T any] struct {
	Data []T      `json:"data"`
	Meta PageMeta `json:"meta"`
}

// SortKey — hasil parsing sort: prefix '-' = desc, '+'/tanpa = asc.
type SortKey struct {
	Field string
	Desc  bool
}

// PageRequest — padanan page-request.dto.ts.
type PageRequest struct {
	Page    int
	Limit   int
	Offset  int
	Sort    []SortKey
	Filters map[string]string // filter[k]=v + query key bebas non-reserved
}

const (
	defaultPage  = 1
	defaultLimit = 20
	maxLimit     = 200
)

var sortFieldRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_.]*$`)

// ParsePageRequest mem-parsing query persis NestJS: default 1/20, clamp 200,
// sort `-field` → desc, `filter[k]=v`, query key bebas masuk filters.
// Gagal integer/sort tidak valid → *DomainError VAL-400 (field issue).
func ParsePageRequest(q url.Values) (*PageRequest, error) {
	pr := &PageRequest{Page: defaultPage, Limit: defaultLimit, Filters: map[string]string{}}

	if v := q.Get("page"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return nil, Validation([]FieldIssue{{Field: "page", Message: fmt.Sprintf("Harus bilangan bulat >= 1 (diterima: %s).", strconv.Quote(v))}})
		}
		pr.Page = n
	}
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return nil, Validation([]FieldIssue{{Field: "limit", Message: fmt.Sprintf("Harus bilangan bulat >= 1 (diterima: %s).", strconv.Quote(v))}})
		}
		if n > maxLimit {
			n = maxLimit
		}
		pr.Limit = n
	}
	pr.Offset = (pr.Page - 1) * pr.Limit

	if v := q.Get("sort"); v != "" {
		for _, raw := range splitComma(v) {
			desc := false
			field := raw
			if len(field) > 0 && field[0] == '-' {
				desc = true
				field = field[1:]
			} else if len(field) > 0 && field[0] == '+' {
				field = field[1:]
			}
			if !sortFieldRe.MatchString(field) {
				return nil, Validation([]FieldIssue{{Field: "sort", Message: fmt.Sprintf("Nama field sort tidak valid: %s.", strconv.Quote(raw))}})
			}
			pr.Sort = append(pr.Sort, SortKey{Field: field, Desc: desc})
		}
	}

	for key, vals := range q {
		if len(vals) == 0 {
			continue
		}
		switch key {
		case "page", "limit", "sort":
			continue
		}
		if len(key) > 7 && key[:7] == "filter[" && key[len(key)-1] == ']' {
			pr.Filters[key[7:len(key)-1]] = vals[0]
			continue
		}
		pr.Filters[key] = vals[0]
	}
	return pr, nil
}

func splitComma(s string) []string {
	var out []string
	cur := ""
	for _, r := range s {
		if r == ',' {
			if cur != "" {
				out = append(out, cur)
			}
			cur = ""
			continue
		}
		cur += string(r)
	}
	if cur != "" {
		out = append(out, cur)
	}
	return out
}

// BuildPage — padanan buildPage: totalPages = ceil(max(0,total)/max(1,limit)).
func BuildPage[T any](data []T, total int, pr *PageRequest) Page[T] {
	lim := pr.Limit
	if lim < 1 {
		lim = 1
	}
	tp := (total + lim - 1) / lim
	if total < 0 {
		tp = 0
	}
	if data == nil {
		data = []T{}
	}
	return Page[T]{Data: data, Meta: PageMeta{Page: pr.Page, Limit: pr.Limit, Total: total, TotalPages: tp}}
}
