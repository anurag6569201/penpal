from django.urls import path

from . import views

urlpatterns = [
    path("health/", views.health, name="health"),
    path("chat/", views.chat, name="chat"),
    path("read-math/", views.read_math, name="read-math"),
    path("solve-math/", views.solve_math, name="solve-math"),
    path("worksheet/", views.worksheet, name="worksheet"),
    path("check-work/", views.check_work, name="check-work"),
    path("practice/", views.practice, name="practice"),
    path("solve-stream/", views.solve_stream, name="solve-stream"),
]
