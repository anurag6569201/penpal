from django.urls import path

from . import views

urlpatterns = [
    path("health/", views.health, name="health"),
    path("chat/", views.chat, name="chat"),
    path("read-math/", views.read_math, name="read-math"),
    path("solve-math/", views.solve_math, name="solve-math"),
]
