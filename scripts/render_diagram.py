"""Render the TravelMemory deployment architecture diagram to a PNG."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

fig, ax = plt.subplots(figsize=(10, 13))
ax.set_xlim(0, 10)
ax.set_ylim(0, 14)
ax.axis("off")

COL = {
    "user":   "#dae8fc",
    "cf":     "#ffe6cc",
    "alb":    "#d5e8d4",
    "host":   "#f5f5f5",
    "nginx":  "#dae8fc",
    "fe":     "#fff2cc",
    "be":     "#e1d5e7",
    "db":     "#d5e8d4",
}
EDGE = {
    "user":   "#6c8ebf",
    "cf":     "#d79b00",
    "alb":    "#82b366",
    "host":   "#666666",
    "nginx":  "#6c8ebf",
    "fe":     "#d6b656",
    "be":     "#9673a6",
    "db":     "#82b366",
}


def box(x, y, w, h, text, key, fontsize=10, weight="normal", va_top=False):
    ax.add_patch(FancyBboxPatch(
        (x, y), w, h, boxstyle="round,pad=0.02,rounding_size=0.12",
        linewidth=1.5, edgecolor=EDGE[key], facecolor=COL[key]))
    ty = y + h - 0.28 if va_top else y + h / 2
    ax.text(x + w / 2, ty, text, ha="center",
            va="top" if va_top else "center",
            fontsize=fontsize, fontweight=weight, wrap=True)


def arrow(x1, y1, x2, y2, dashed=False):
    ax.add_patch(FancyArrowPatch(
        (x1, y1), (x2, y2), arrowstyle="-|>", mutation_scale=16,
        linewidth=1.4, color="#333333",
        linestyle="--" if dashed else "-", shrinkA=2, shrinkB=2))


# Title
ax.text(5, 13.6, "TravelMemory — AWS Deployment Architecture",
        ha="center", va="center", fontsize=15, fontweight="bold")

# User
box(4.0, 12.2, 2.0, 0.9, "End User\n(Browser)", "user", weight="bold")
# Cloudflare
box(2.8, 10.6, 4.4, 1.1,
    "Cloudflare — Custom Domain\nDNS + SSL/TLS\nA record -> EC2 IP   |   CNAME -> ALB endpoint",
    "cf", fontsize=9.5)
# ALB
box(3.0, 9.0, 4.0, 1.1,
    "Application Load Balancer (ALB)\nListener :80 / :443\nTarget Group (HTTP :80)", "alb", fontsize=9.5)

# Hosts
box(0.6, 4.4, 3.9, 3.7, "EC2 Instance #1  (AZ-a)", "host", fontsize=10, weight="bold", va_top=True)
box(5.5, 4.4, 3.9, 3.7, "EC2 Instance #2  (AZ-b)", "host", fontsize=10, weight="bold", va_top=True)

# Inner components #1
box(0.9, 6.7, 3.3, 0.8, "Nginx :80\n(reverse proxy + static)", "nginx", fontsize=9)
box(0.9, 5.7, 3.3, 0.7, "React Frontend (build)", "fe", fontsize=9)
box(0.9, 4.7, 3.3, 0.7, "Node / Express :3000 (PM2)", "be", fontsize=9)
# Inner components #2
box(5.8, 6.7, 3.3, 0.8, "Nginx :80\n(reverse proxy + static)", "nginx", fontsize=9)
box(5.8, 5.7, 3.3, 0.7, "React Frontend (build)", "fe", fontsize=9)
box(5.8, 4.7, 3.3, 0.7, "Node / Express :3000 (PM2)", "be", fontsize=9)

# Database
box(3.5, 2.4, 3.0, 1.0, "MongoDB Atlas\n(managed database)", "db", fontsize=10, weight="bold")

# Arrows
arrow(5.0, 12.2, 5.0, 11.7)          # user -> cf
arrow(5.0, 10.6, 5.0, 10.1)          # cf -> alb
arrow(4.2, 9.0, 2.8, 7.5)            # alb -> nginx1
arrow(5.8, 9.0, 7.2, 7.5)            # alb -> nginx2
arrow(2.55, 4.7, 4.2, 3.4, dashed=True)   # be1 -> db
arrow(7.45, 4.7, 5.8, 3.4, dashed=True)   # be2 -> db

# Legend
ax.text(5, 1.6, "Solid = HTTP request path    •    Dashed = database connection",
        ha="center", va="center", fontsize=9, style="italic", color="#555555")

plt.tight_layout()
fig.savefig("screenshots/11-architecture.png", dpi=150, bbox_inches="tight")
print("Saved screenshots/11-architecture.png")
